// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 that skims a fee on every transfer: the recipient receives `amount - fee`
///         (the fee is burned). Models USDT-style fee-on-transfer behaviour so tests can
///         verify the executors reject tokens that deliver less than the requested amount.
contract MockFeeOnTransferERC20 is ERC20 {
    uint256 public immutable feeBps;

    constructor(string memory name_, string memory symbol_, uint256 feeBps_) ERC20(name_, symbol_) {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        // Skim on real transfers only (not mint/burn): burn the fee out of what arrived.
        if (from != address(0) && to != address(0)) {
            uint256 fee = (value * feeBps) / 10_000;
            if (fee > 0) {
                super._update(to, address(0), fee);
            }
        }
    }
}
