// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";
import {TokenHolder_v2} from "@bao/TokenHolder_v2.sol";

import {ISwapExecutor} from "@harbor-swap/interfaces/ISwapExecutor.sol";
import {SwapExecutorBase} from "@harbor-swap/SwapExecutorBase.sol";
import {ConfigWstEthWbtcRoute_ETH_mainnet} from "@harbor-swap/config/ConfigWstEthWbtcRoute_ETH_mainnet.sol";

/// @title WstEthWbtcSwapper_v1
/// @notice One-way composite `ISwapExecutor` for wstETH → WBTC (hyBTC peg-equiv).
/// @dev UniV3 multi-hop: wstETH → WETH (0.01%) → WBTC (0.05%). Reverse via Velora.
/// @custom:oz-upgrades-unsafe-allow state-variable-immutable constructor
// slither-disable-next-line missing-inheritance
contract WstEthWbtcSwapper_v1 is// solhint-disable-line contract-name-capwords
 ISwapExecutor, HarborOwnableRoles, Initializable, UUPSUpgradeable, TokenHolder_v2, SwapExecutorBase {
    using SafeERC20 for IERC20;

    error UnsupportedPair(address fromToken, address toToken);

    event WstEthWbtcSwap(
        address indexed caller,
        address indexed fromToken,
        address indexed toToken,
        uint256 amountIn,
        uint256 amountOut
    );

    ISwapRouter public immutable ROUTER;

    constructor(address uniV3Router_) {
        _disableInitializers();
        ROUTER = ISwapRouter(uniV3Router_);
    }

    function initialize(address deployerOwner_, address pendingOwner_) external initializer {
        _initializeOwner(deployerOwner_, pendingOwner_);
    }

    /// @inheritdoc ISwapExecutor
    function swap(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut
    ) external override nonReentrant returns (uint256 amountOut) {
        (amountOut, ) = _swapEnvelope(fromToken, toToken, amountIn, minAmountOut, "");
    }

    function _execute(
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes memory
    ) internal override {
        if (fromToken != _wstEth() || toToken != _wbtc()) {
            revert UnsupportedPair(fromToken, toToken);
        }

        IERC20(_wstEth()).forceApprove(address(ROUTER), amountIn);
        uint256 amountOut = ROUTER.exactInput(
            ISwapRouter.ExactInputParams({
                path: _uniPath(),
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut
            })
        );
        IERC20(_wstEth()).forceApprove(address(ROUTER), 0);

        emit WstEthWbtcSwap(msg.sender, _wstEth(), _wbtc(), amountIn, amountOut);
    }

    function _wstEth() internal view virtual returns (address) {
        return ConfigWstEthWbtcRoute_ETH_mainnet.WSTETH;
    }

    function _wbtc() internal view virtual returns (address) {
        return ConfigWstEthWbtcRoute_ETH_mainnet.WBTC;
    }

    function _uniPath() internal view virtual returns (bytes memory) {
        return ConfigWstEthWbtcRoute_ETH_mainnet.uniPath();
    }

    function _authorizeUpgrade(address) internal override onlyOwner {} // solhint-disable-line no-empty-blocks
}
