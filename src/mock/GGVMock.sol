// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {IStETH} from "src/interfaces/IStETH.sol";

library BorrowedMath {
    uint256 internal constant MAX_UINT256 = 2**256 - 1;

    // author: Solmate (https://github.com/transmissions11/solmate/blob/main/src/utils/FixedPointMathLib.sol)
    function mulDivDown(
        uint256 x,
        uint256 y,
        uint256 denominator
    ) internal pure returns (uint256 z) {
        /// @solidity memory-safe-assembly
        assembly {
            // Equivalent to require(denominator != 0 && (y == 0 || x <= type(uint256).max / y))
            if iszero(mul(denominator, iszero(mul(y, gt(x, div(MAX_UINT256, y)))))) {
                revert(0, 0)
            }

            // Divide x * y by the denominator.
            z := div(mul(x, y), denominator)
        }
    }
}


contract GGVMockTeller is ITellerWithMultiAssetSupport {
    struct Asset {
        bool allowDeposits;
        bool allowWithdraws;
        uint16 sharePremium;
    }

    address public immutable owner;
    GGVVaultMock public immutable _vault;
    uint256 internal immutable ONE_SHARE;
    IStETH public immutable steth;

    mapping(ERC20 asset => Asset) public assets;


    constructor(address _owner, address __vault, address _steth) {
        owner = _owner;
        _vault = GGVVaultMock(__vault);
        steth = IStETH(_steth);
        
        // eq to 10 ** vault.decimals()
        ONE_SHARE = 10 ** 18;

        _updateAssetData(ERC20(address(steth)), true, true, 0);
    }

    function deposit(ERC20 depositAsset, uint256 depositAmount, uint256 minimumMint) external returns (uint256 shares){
        Asset memory asset = assets[depositAsset];
        if (!asset.allowDeposits) {
            revert('Deposits not allowed');
        }
        if (depositAmount == 0) {
            revert('Deposit amount must be greater than 0');
        }
        if( depositAsset != ERC20(address(steth))) {
            revert("Asset not supported");
        }

        // hardcode share calculation for only steth
        shares = _vault.getSharesByAssets(steth.getSharesByPooledEth(depositAmount));
        // apply premium if any
        shares = asset.sharePremium > 0 ? BorrowedMath.mulDivDown(shares,1e4 - asset.sharePremium, 1e4) : shares;

        if( shares < minimumMint) {
            revert('Minted shares less than minimumMint');
        }

        _vault.depositByTeller(address(depositAsset), shares, depositAmount, msg.sender);
        
    }

    

    function _updateAssetData(ERC20 asset, bool allowDeposits, bool allowWithdraws, uint16 sharePremium) internal {
        if(address(asset) != address(steth)) {
            revert("Asset not supported");
        }
        assets[asset] = Asset(allowDeposits, allowWithdraws, sharePremium);
    }

    function updateAssetData(ERC20 asset, bool allowDeposits, bool allowWithdraws, uint16 sharePremium) external {
        require(msg.sender == owner, "Only owner can update asset data");
        _updateAssetData(asset, allowDeposits, allowWithdraws, sharePremium);
    }




    function authority() external view returns (address){
        return owner;
    }

    function vault() external view returns (address){
      return address(_vault);
    }

    // STUBS    

    function accountant() external view  returns (address){
      return address(this);
    }

    event NonPure();

    function bulkDeposit(ERC20, uint256, uint256, address) external returns (uint256) {
        emit NonPure();
        revert('not implemented');
     }
    function bulkWithdraw(ERC20, uint256, uint256, address) external returns (uint256) {
        emit NonPure();
        revert('not implemented');
    }   


}

contract GGVQueueMock is IBoringOnChainQueue{
    using EnumerableSet for EnumerableSet.Bytes32Set;
    
    uint256 internal immutable ONE_SHARE;
    address public immutable _owner;
    GGVVaultMock public immutable _vault;
    IStETH public immutable steth;


    EnumerableSet.Bytes32Set private _withdrawRequests;
    uint96 public nonce = 1;
    mapping(address assetOut => WithdrawAsset) public _withdrawAssets;
    mapping(bytes32 requestId => OnChainWithdraw) internal _helper_requestsById;

    event OnChainWithdrawRequested(
        bytes32 indexed requestId,
        address indexed user,
        address indexed assetOut,
        uint96 nonce,
        uint128 amountOfShares,
        uint128 amountOfAssets,
        uint40 creationTime,
        uint24 secondsToMaturity,
        uint24 secondsToDeadline
    );

    constructor(address __vault, address _steth, address __owner) {
        _owner = __owner;
        _vault = GGVVaultMock(__vault);
        steth = IStETH(_steth);
        ONE_SHARE = 10 ** 18;

        // allow withdraws for steth by default
        _updateWithdrawAsset(address(steth), 0, 0, 0, 500, 100); 
    }


    function owner() external view returns (address) {
        return _owner;
    }

    function authority() external view returns (address) {
        return _owner;
    }
    function boringVault() external view returns (address) {
        return address(_vault);
    }
    function accountant() external view returns (address) {
        return address(this);
    }

    function withdrawAssets(address assetOut) external view returns (WithdrawAsset memory) {
        return _withdrawAssets[assetOut];
    }

    function updateWithdrawAsset(address assetOut, uint24 secondsToMaturity, uint24 minimumSecondsToDeadline, uint16 minDiscount, uint16 maxDiscount, uint96 minimumShares) external {
        require(msg.sender == _owner, "Only owner can update withdraw asset");
       _updateWithdrawAsset(assetOut, secondsToMaturity, minimumSecondsToDeadline, minDiscount, maxDiscount, minimumShares);
    }




    function setWithdrawCapacity(address assetOut, uint256 withdrawCapacity) external {
       require(msg.sender == _owner, "Only owner can update withdraw asset");
        _withdrawAssets[assetOut].withdrawCapacity = withdrawCapacity;
    }
    

    function requestOnChainWithdraw(address assetOut, uint128 amountOfShares, uint16 discount, uint24 secondsToDeadline) external returns (bytes32 requestId){
        WithdrawAsset memory withdrawAsset = _withdrawAssets[assetOut];
        _beforeNewRequest(withdrawAsset, amountOfShares, discount, secondsToDeadline);

        // hardcode for steth only
        if( assetOut != address(steth)) {
            revert("Only steth supported");
        }

        uint128 amountOfAssets = uint128(_vault.getAssetsByShares(amountOfShares));
        if( amountOfAssets > steth.sharesOf(address(_vault))) {
            revert("Not enough assets in vault");
        }

        // needs approval
        _vault.transferFrom(msg.sender, address(this), amountOfShares);

        uint96 requestNonce;
        // See nonce definition for unchecked safety.
        unchecked {
            // Set request nonce as current nonce, then increment nonce.
            requestNonce = nonce++;
        }


        uint128 amountOfAssets128 = previewAssetsOut(assetOut, amountOfShares, discount);

        uint40 timeNow = uint40(block.timestamp); // Safe to cast to uint40 as it won't overflow for 10s of thousands of years
        OnChainWithdraw memory req = OnChainWithdraw({
            nonce: requestNonce,
            user: msg.sender,
            assetOut: assetOut,
            amountOfShares: amountOfShares,
            amountOfAssets: amountOfAssets128,
            creationTime: timeNow,
            secondsToMaturity: withdrawAsset.secondsToMaturity,
            secondsToDeadline: secondsToDeadline
        });


        requestId = keccak256(abi.encode(req));

        // write to onchain storage for easier tests
        _helper_requestsById[requestId] = req;


        _withdrawRequests.add(requestId);
        nonce++;

        _decrementWithdrawCapacity(assetOut, amountOfShares);

        emit OnChainWithdrawRequested(
            requestId,
            msg.sender,
            assetOut,
            requestNonce,
            amountOfShares,
            amountOfAssets128,
            timeNow,
            withdrawAsset.secondsToMaturity,
            secondsToDeadline
        );

        return requestId;
    }
    
    function getRequestIds() external view returns (bytes32[] memory){
        return _withdrawRequests.values();
    }

    function mockGetRequestById(bytes32 requestId) external view returns (OnChainWithdraw memory){
        return _helper_requestsById[requestId];
    }

   function solveOnChainWithdraws(OnChainWithdraw[] calldata requests, bytes calldata, address)
        external
    {

        ERC20 solveAsset = ERC20(requests[0].assetOut);
        uint256 requiredAssets;
        uint256 totalShares;
        uint256 requestsLength = requests.length;
        for (uint256 i = 0; i < requestsLength; ++i) {
            if (address(solveAsset) != requests[i].assetOut) revert('solve asset mismatch');
            uint256 maturity = requests[i].creationTime + requests[i].secondsToMaturity;
            if (block.timestamp < maturity) revert('not matured');
            uint256 deadline = maturity + requests[i].secondsToDeadline;
            if (block.timestamp > deadline) revert('deadline passed');
            requiredAssets += requests[i].amountOfAssets;
            totalShares += requests[i].amountOfShares;
            _dequeueOnChainWithdraw(requests[i]);
            //emit OnChainWithdrawSolved(requestId, requests[i].user, block.timestamp);
            _vault.burnSharesReturnAssets(requests[i].amountOfShares, requests[i].amountOfAssets, requests[i].user);
        }
    }

     function cancelOnChainWithdraw(OnChainWithdraw memory request) external returns (bytes32 requestId) {
         require(msg.sender == request.user, "Only request creator can cancel");
         requestId = _dequeueOnChainWithdraw(request);
        _incrementWithdrawCapacity(request.assetOut, request.amountOfShares);
        require(_vault.transfer(request.user, request.amountOfShares));
    }

    function previewAssetsOut(address assetOut, uint128 amountOfShares, uint16 discount)
        public
        view
        returns (uint128 amountOfAssets128)
    {
        require(assetOut == address(steth), "Only steth supported");


        //uint256 price = accountant.getRateInQuoteSafe(ERC20(assetOut));
        // assets(steth shares) per 1 share
        uint256 price = _vault.getAssetsByShares(ONE_SHARE);
        // discount
        price = BorrowedMath.mulDivDown(price, 1e4 - discount, 1e4);
        // shares * (price == assets * ONE_SHARE ) / one _share
        uint256 amountOfAssets = BorrowedMath.mulDivDown(uint256(amountOfShares),price, ONE_SHARE);
        if (amountOfAssets > type(uint128).max) revert('overflow');

        

        amountOfAssets128 = uint128(amountOfAssets);
    } 

    event NonPure();
    function replaceOnChainWithdraw(OnChainWithdraw memory, uint16, uint24) external returns (bytes32, bytes32) {
        emit NonPure();
        revert('not implemented');
    }

    function _beforeNewRequest(
        WithdrawAsset memory withdrawAsset,
        uint128 amountOfShares,
        uint16 discount,
        uint24 secondsToDeadline
    ) internal view virtual {
        if (!withdrawAsset.allowWithdraws) revert('Withdraws not allowed');
        if (discount < withdrawAsset.minDiscount || discount > withdrawAsset.maxDiscount) {
            revert('Bad discount');
        }
        if (amountOfShares < withdrawAsset.minimumShares) revert('Bad share amount');
        if (secondsToDeadline < withdrawAsset.minimumSecondsToDeadline) revert('Bad deadline');
    }

     function _decrementWithdrawCapacity(address assetOut, uint256 amountOfShares) internal {
        WithdrawAsset storage withdrawAsset = _withdrawAssets[assetOut];
        if (withdrawAsset.withdrawCapacity < type(uint256).max) {
            if (withdrawAsset.withdrawCapacity < amountOfShares) revert('Not enough capacity');
            withdrawAsset.withdrawCapacity -= amountOfShares;
        }
    }

    function _incrementWithdrawCapacity(address assetOut, uint256 amountOfShares) internal {
        WithdrawAsset storage withdrawAsset = _withdrawAssets[assetOut];
        if (withdrawAsset.withdrawCapacity < type(uint256).max) {
            withdrawAsset.withdrawCapacity += amountOfShares;
        }
    }

    function _dequeueOnChainWithdraw(OnChainWithdraw memory request) internal virtual returns (bytes32 requestId) {
        // Remove request from queue.
        requestId = keccak256(abi.encode(request));
        bool removedFromSet = _withdrawRequests.remove(requestId);
        if (!removedFromSet) revert('request not found');
    }

    
    function _updateWithdrawAsset(address assetOut, uint24 secondsToMaturity, uint24 minimumSecondsToDeadline, uint16 minDiscount, uint16 maxDiscount, uint96 minimumShares) internal {
        _withdrawAssets[assetOut] = WithdrawAsset(true, secondsToMaturity, minimumSecondsToDeadline, minDiscount, maxDiscount, minimumShares, type(uint256).max);
    }



}

contract GGVVaultMock is ERC20  {
    address public immutable owner;
    ITellerWithMultiAssetSupport public immutable TELLER;
    GGVQueueMock public immutable BORING_QUEUE;
    IStETH public immutable steth;

    // steth shares as base vault asset
    // real ggv uses weth but it should be okay to peg it to steth shares for mock
    uint256 public _totalAssets;

    constructor(address _owner, address _steth) ERC20("GGVVaultMock", "tGGV")  {
        owner = _owner;
        TELLER = ITellerWithMultiAssetSupport(address(new GGVMockTeller(_owner, address(this), _steth)));
        BORING_QUEUE = new GGVQueueMock(address(this), _steth, _owner);
        steth = IStETH(_steth);

        // Mint some initial tokens to the dead address to avoid zero totalSupply issues
        _mint(address(0xdead), 1e18);
        _totalAssets = 1e18;
    }

    function rebase(uint256 stethSharesToRebaseWith) external {
        require(msg.sender == owner, "Only owner can rebase");
        steth.transferSharesFrom(msg.sender, address(this), stethSharesToRebaseWith);
        _totalAssets += stethSharesToRebaseWith;
    }

    function negativeRebase(uint256 stethSharesToRebaseWith) external {
        require(msg.sender == owner, "Only owner can rebase");
        steth.transferShares(msg.sender, stethSharesToRebaseWith);
        _totalAssets -= stethSharesToRebaseWith;
    }
    

    function getSharesByAssets(uint256 assets) public view returns (uint256) {
       return BorrowedMath.mulDivDown(assets, totalSupply(), _totalAssets);
    }

    function getAssetsByShares(uint256 shares) public view returns (uint256) {
       return BorrowedMath.mulDivDown(shares, _totalAssets, totalSupply());
    }


    function depositByTeller( address asset,uint256 shares,uint256 assets, address user) external  {
        require(msg.sender == address(TELLER), "Only teller can call depositByTeller");
        
        
        require(asset == address(steth), "Only steth asset supported");
        steth.transferSharesFrom(user, address(this), assets);

        _mint(user, shares);
        _totalAssets += assets;
    }

    function burnSharesReturnAssets(uint256 shares, uint256 assets, address user) external {
        require(msg.sender == address(BORING_QUEUE), "Only queue can call burnShares");
        _burn(address(BORING_QUEUE), shares);
        _totalAssets -= assets;
        steth.transferShares(user, assets);
    }

}