// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title IIssuerAdapter
 * @notice What a token issuer implements to plug into the Mint-to-Liquidity hook.
 * @dev Prices are WAD-scaled ratios of raw base units (`quote units * 1e18 / token units`),
 * so `quote = tokens * price / 1e18` holds whatever the two currencies' decimals are.
 *
 * The anchor rule: neither price may read the pool the hook guards.
 */
interface IIssuerAdapter {
    /**
     * @notice The mintable token the pool trades.
     */
    function token() external view returns (IERC20);

    /**
     * @notice The asset the issuer mints and redeems against: native ETH (address zero) or an ERC-20.
     */
    function quoteCurrency() external view returns (Currency);

    /**
     * @notice The band's ceiling: what one token costs to mint.
     * @return _ceiling Quote per token, WAD.
     */
    function mintPrice() external view returns (uint256 _ceiling);

    /**
     * @notice The band's floor: what one token redeems for.
     * @return _floor Quote per token, WAD. Zero means "same as `mintPrice()`" (a single price).
     */
    function redeemPrice() external view returns (uint256 _floor);

    /**
     * @notice The quote the issuer can pay out for redemptions right now.
     * @return _quoteOut Immediate exit capacity. Zero means the token has no redemption.
     */
    function maxRedeemNow() external view returns (uint256 _quoteOut);

    /**
     * @notice Mints tokens to the caller at `mintPrice()`.
     * @dev For native ETH, `msg.value` must equal `_quoteIn`. For an ERC-20, the adapter pulls
     * `_quoteIn` from the caller, which approves exactly that amount beforehand.
     * @param _quoteIn Quote paid.
     * @param _minTokens Minimum tokens the caller accepts; the call reverts below it.
     * @return _tokensOut Tokens sent to the caller.
     */
    function mint(uint256 _quoteIn, uint256 _minTokens) external payable returns (uint256 _tokensOut);

    /**
     * @notice Redeems the caller's tokens at `redeemPrice()` and pays the quote to the caller.
     * @dev The adapter pulls `_tokens` from the caller, which approves exactly that amount beforehand.
     * Must revert instead of queueing when the redemption cannot be paid immediately.
     * @param _tokens Tokens redeemed.
     * @param _minQuote Minimum quote the caller accepts; the call reverts below it.
     * @return _quoteOut Quote sent to the caller.
     */
    function redeem(uint256 _tokens, uint256 _minQuote) external returns (uint256 _quoteOut);

    /**
     * @notice Who receives the hook's rebalance profit and rounding dust.
     */
    function beneficiary() external view returns (address);

    /**
     * @notice Who may register pools for this adapter on the hook.
     */
    function owner() external view returns (address);
}
