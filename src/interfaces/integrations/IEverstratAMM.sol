// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IEverstratAMM
 * @notice The part of the Everstrat AMM the adapter uses. See `everstrat-xyz/contracts` (`IAMM`).
 */
interface IEverstratAMM {
    /**
     * @notice Mints EVE to the caller for `msg.value` ETH at the premium price.
     * @param _minTokensToMint Minimum EVE to mint; must be non-zero.
     */
    function enter(uint256 _minTokensToMint) external payable;

    /**
     * @notice Burns the caller's EVE for ETH at the base price, or queues the redemption when the
     * AMM's free ETH cannot cover it.
     * @param _requestedETH ETH to redeem.
     * @param _maxTokensToBurn Maximum EVE to burn.
     * @param _priceTolerance Relative slippage allowed on a queued redemption, WAD.
     * @return _batchId Zero for an immediate redemption, the queue batch id otherwise.
     */
    function exit(uint256 _requestedETH, uint256 _maxTokensToBurn, uint256 _priceTolerance)
        external
        returns (uint256 _batchId);

    /**
     * @notice What one EVE costs to mint, in ETH, WAD.
     */
    function evePremiumPriceInETH() external view returns (uint256);

    /**
     * @notice What one EVE redeems for, in ETH, WAD.
     */
    function eveBasePriceInETH() external view returns (uint256);

    /**
     * @notice ETH the AMM can pay out for immediate redemptions.
     */
    function freeBalance() external view returns (uint256);
}
