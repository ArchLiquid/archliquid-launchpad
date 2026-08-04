# Third-party deployment artifacts

ArchLiquid's source code remains governed by the repository's proprietary
license. The Robinhood testnet V2 fixture separately deploys
unmodified compiled artifacts from the following upstream packages:

| Artifact | Package | Version | License |
| --- | --- | --- | --- |
| `UniswapV2Factory` | `@uniswap/v2-core` | `1.0.1` | GPL-3.0-or-later |
| `UniswapV2Router02` | `@uniswap/v2-periphery` | `1.1.0-beta.0` | GPL-3.0-or-later |

The upstream packages and their license texts are available from the official
[Uniswap V2 core](https://github.com/Uniswap/v2-core) and
[Uniswap V2 periphery](https://github.com/Uniswap/v2-periphery) repositories.
The JSON files under `vendor-artifacts/uniswap-v2` record the exact package
version, bytecode, and SHA-256 digest consumed by the deployment script.

These notices do not relicense any ArchLiquid-authored source.
