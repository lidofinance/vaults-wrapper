// SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {BorrowedMath} from "./BorrowedMath.sol";
import {GGVMockTeller} from "./GGVMockTeller.sol";
import {GGVQueueMock} from "./GGVQueueMock.sol";
import {IStETH} from "src/interfaces/IStETH.sol";
import {IWstETH} from "src/interfaces/IWstETH.sol";
import {IBoringOnChainQueue} from "src/interfaces/ggv/IBoringOnChainQueue.sol";
import {ITellerWithMultiAssetSupport} from "src/interfaces/ggv/ITellerWithMultiAssetSupport.sol";

contract GGVVaultMock is ERC20 {
    address public immutable owner;
    ITellerWithMultiAssetSupport public immutable TELLER;
    GGVQueueMock public immutable BORING_QUEUE;
    IStETH public immutable steth;
    IWstETH public immutable wsteth;

    // steth shares as base vault asset
    // real ggv uses weth but it should be okay to peg it to steth shares for mock
    uint256 public _totalAssets;

    constructor(address _owner, address _steth, address _wsteth) ERC20("GGVVaultMock", "tGGV") {
        owner = _owner;
        TELLER = ITellerWithMultiAssetSupport(address(new GGVMockTeller(_owner, address(this), _steth, _wsteth)));
        BORING_QUEUE = new GGVQueueMock(address(this), _steth, _wsteth, _owner);
        steth = IStETH(_steth);
        wsteth = IWstETH(_wsteth);

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
        uint256 supply = totalSupply();
        uint256 totalAssets_ = totalAssets();
        if (supply == 0 || totalAssets_ == 0) return assets;

        return BorrowedMath.mulDivDown(assets, supply, totalAssets_);
    }

    function getAssetsByShares(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply();
        uint256 totalAssets_ = totalAssets();
        if (supply == 0) return shares;
        return BorrowedMath.mulDivDown(shares, totalAssets_, supply);
    }

    function depositByTeller(address asset, uint256 shares, uint256 assets, address user) external {
        require(msg.sender == address(TELLER), "Only teller can call depositByTeller");

        if (asset == address(steth)) {
            steth.transferSharesFrom(user, address(this), assets);
        } else if (asset == address(wsteth)) {
            wsteth.transferFrom(user, address(this), assets);
        } else {
            revert("Unsupported asset");
        }

        _mint(user, shares);
        _totalAssets += assets;
    }

    function burnSharesReturnAssets(ERC20 assetOut, uint256 shares, uint256 assets, address user) external {
        require(msg.sender == address(BORING_QUEUE), "Only queue can call burnShares");
        _burn(address(BORING_QUEUE), shares);
        _totalAssets -= assets;
        assetOut.transfer(user, assets);
    }

    function totalAssets() public view returns (uint256) {
        return _totalAssets;
    }
}
