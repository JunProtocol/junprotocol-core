// SPDX-License-Identifier: MIT
pragma solidity >= 0.5.0;

interface ITreasury {
    function round() external view returns (uint256);

    function nextRoundPoint() external view returns (uint256);

    function getJUNPrice() external view returns (uint256);

    function buyJUNB(uint256 amount, uint256 targetPrice) external;

    function redeemJUNB(uint256 amount, uint256 targetPrice) external;
}
