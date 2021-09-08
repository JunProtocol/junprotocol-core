// SPDX-License-Identifier: MIT
pragma solidity 0.5.6;

import "../owner/Operator.sol";
import "./kERC20.sol";

contract JUNBond is kERC20, Operator {
    /**
     * @notice Constructs the JUN Bond ERC-20 contract.
     */
    constructor() public kERC20("Jun Bond Token", "JUNB") {
        // Mints JUNB to contract creator for initial pool setup
        _mint(msg.sender, 1 ether);
    }

    /**
     * @notice Operator mints JUNB to a recipient
     * @param recipient_ The address of recipient
     * @param amount_ The amount of JUNB to mint to
     * @return whether the process has been done
     */
    function mint(address recipient_, uint256 amount_) public onlyOperator returns (bool) {
        uint256 balanceBefore = balanceOf(recipient_);
        _mint(recipient_, amount_);
        uint256 balanceAfter = balanceOf(recipient_);

        return balanceAfter > balanceBefore;
    }

    function burn(uint256 amount) public onlyOperator {
        super.burn(amount);
    }

    function burnFrom(address account, uint256 amount) public onlyOperator {
        super.burnFrom(account, amount);
    }
}
