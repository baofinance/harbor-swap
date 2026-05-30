// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

/// @notice Mock for the fxSAVE/scrvUSD Curve pool where coin(1) is the scrvUSD ERC4626 vault.
///         `exchange(0, 1, dx, min_dy)` pulls fxSAVE and deposits crvUSD into the vault for
///         the caller, mimicking the mainnet pool output of vault shares.
contract MockFxSaveScrvUsdPool {
    address public immutable fxSAVE;
    IERC4626 public immutable vault;
    uint256 public rate = 1e18;
    bool public shouldRevert;
    address public reentrantTarget;
    bytes public reentrantCalldata;

    constructor(address fxSAVE_, IERC4626 vault_) {
        fxSAVE = fxSAVE_;
        vault = vault_;
    }

    function setRate(uint256 rate_) external {
        rate = rate_;
    }

    function setShouldRevert(bool revert_) external {
        shouldRevert = revert_;
    }

    function setReentrantCall(address target_, bytes calldata calldata_) external {
        reentrantTarget = target_;
        reentrantCalldata = calldata_;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external returns (uint256 shares) {
        if (shouldRevert) {
            revert("MockFxSaveScrvUsdPool: forced revert");
        }
        require(i == 0 && j == 1, "MockFxSaveScrvUsdPool: bad indices");
        IERC20(fxSAVE).transferFrom(msg.sender, address(this), dx);
        uint256 crvUsd = (dx * rate) / 1e18;
        MockERC20(address(vault.asset())).mint(address(this), crvUsd);
        IERC20(vault.asset()).approve(address(vault), crvUsd);
        shares = vault.deposit(crvUsd, msg.sender);
        require(shares >= min_dy, "MockFxSaveScrvUsdPool: slippage");

        if (reentrantTarget != address(0)) {
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, ) = reentrantTarget.call(reentrantCalldata);
            require(ok, "MockFxSaveScrvUsdPool: reentrant call failed");
        }
    }
}
