# Wake Fuzzing for Lido Vaults Wrapper

This directory contains fuzz tests written with [Wake](https://github.com/Ackee-Blockchain/wake).

![horizontal splitter](https://github.com/Ackee-Blockchain/wake-detect-action/assets/56036748/ec488c85-2f7f-4433-ae58-3d50698a47de)

## Quick start

Run all commands from the project root:

```sh
wake up
```

Run the StvPool fuzz test:

```sh
wake test wake_fuzz/test_stvpool_fuzz.py
```

Run the stvStEthPool fuzz test:

```sh
wake test wake_fuzz/test_stvstethpool_fuzz.py
```

## Scope

These tests only cover the vaults-wrapper code.

For Vaults integration fuzzing, see the Ackee Blockchain repository:
- [tests-lido-vaults-wrapper (integration tests with Core repo)](https://github.com/Ackee-Blockchain/tests-lido-vaults-wrapper)

Tested with `wake` version `5.0.0rc1`.
