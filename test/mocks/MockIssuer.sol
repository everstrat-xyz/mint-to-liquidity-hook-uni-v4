// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IIssuerAdapter} from "interfaces/IIssuerAdapter.sol";

import {MockToken} from "./MockToken.sol";

/**
 * @notice Reference issuer that is its own adapter: it mints at a premium over NAV and redeems at NAV.
 *
 * NAV per token is `assets / supply`. A mint adds its quote to `assets`, so minting at a premium
 * lifts NAV for every holder; a redemption pays out at NAV and leaves it unchanged.
 *
 * Test knobs cover what real issuers do: NAV drift, a pause, limited exit liquidity, a single
 * price, redemptions that round twice, and quotes that are simply wrong.
 */
contract MockIssuer is IIssuerAdapter {
    uint256 private constant _WAD = 1e18;

    MockToken private immutable _TOKEN;
    Currency private immutable _QUOTE;

    address public owner;
    address public beneficiary;

    /// @notice Quote backing the supply; NAV per token is `assets / supply`.
    uint256 public assets;
    /// @notice Mint premium over NAV, WAD (0.1e18 = 10%).
    uint256 public premium;
    /// @notice Upper bound on what `maxRedeemNow()` reports, on top of the actual balance.
    uint256 public exitCap = type(uint256).max;
    /// @notice Quote base units a redemption pays below `tokens * redeemPrice`, as a twice-rounding issuer does.
    uint256 public redeemShortfall;
    /// @notice Number of redemptions that were paid although they exceeded `maxRedeemNow()`. Must stay zero.
    uint256 public overCapacityRedemptions;

    bool public paused;
    bool public singlePrice;
    bool public pricesForced;
    uint256 public forcedMintPrice;
    uint256 public forcedRedeemPrice;

    error MockIssuerPaused();
    error MockIssuerValueMismatch();
    error MockIssuerInsufficientOutput();
    error MockIssuerWouldQueue();

    constructor(MockToken _token, Currency _quote, address _owner, address _beneficiary, uint256 _premium) {
        _TOKEN = _token;
        _QUOTE = _quote;
        owner = _owner;
        beneficiary = _beneficiary;
        premium = _premium;
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                               TEST KNOBS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets NAV per token by rewriting the accounting; funds are dealt separately.
    function setNav(uint256 _nav) external {
        assets = (_TOKEN.totalSupply() * _nav) / _WAD;
    }

    function setPremium(uint256 _premium) external {
        premium = _premium;
    }

    function setExitCap(uint256 _exitCap) external {
        exitCap = _exitCap;
    }

    function setRedeemShortfall(uint256 _redeemShortfall) external {
        redeemShortfall = _redeemShortfall;
    }

    function setPaused(bool _paused) external {
        paused = _paused;
    }

    function setSinglePrice(bool _singlePrice) external {
        singlePrice = _singlePrice;
    }

    function setBeneficiary(address _beneficiary) external {
        beneficiary = _beneficiary;
    }

    function forcePrices(uint256 _mintPrice, uint256 _redeemPrice) external {
        pricesForced = true;
        forcedMintPrice = _mintPrice;
        forcedRedeemPrice = _redeemPrice;
    }

    function unforcePrices() external {
        pricesForced = false;
    }

    /*//////////////////////////////////////////////////////////////
                             IIssuerAdapter
    //////////////////////////////////////////////////////////////*/

    function mint(uint256 _quoteIn, uint256 _minTokens) external payable returns (uint256 _tokensOut) {
        if (paused) revert MockIssuerPaused();

        _tokensOut = (_quoteIn * _WAD) / mintPrice();
        if (_tokensOut < _minTokens) revert MockIssuerInsufficientOutput();

        if (_QUOTE.isAddressZero()) {
            if (msg.value != _quoteIn) revert MockIssuerValueMismatch();
        } else {
            IERC20(Currency.unwrap(_QUOTE)).transferFrom(msg.sender, address(this), _quoteIn);
        }

        assets += _quoteIn;
        _TOKEN.mint(msg.sender, _tokensOut);
    }

    function redeem(uint256 _tokens, uint256 _minQuote) external returns (uint256 _quoteOut) {
        if (paused) revert MockIssuerPaused();

        uint256 _owed = (_tokens * nav()) / _WAD;
        if (_owed > maxRedeemNow()) {
            // A real issuer would queue here. An adapter must revert instead; the counter only
            // survives if a caller somehow got paid anyway.
            overCapacityRedemptions++;
            revert MockIssuerWouldQueue();
        }

        _quoteOut = _owed > redeemShortfall ? _owed - redeemShortfall : 0;
        if (_quoteOut < _minQuote) revert MockIssuerInsufficientOutput();

        _TOKEN.transferFrom(msg.sender, address(this), _tokens);
        _TOKEN.burn(address(this), _tokens);
        assets -= _quoteOut;
        _QUOTE.transfer(msg.sender, _quoteOut);
    }

    function token() external view returns (IERC20) {
        return _TOKEN;
    }

    function quoteCurrency() external view returns (Currency) {
        return _QUOTE;
    }

    function redeemPrice() external view returns (uint256) {
        if (pricesForced) return forcedRedeemPrice;

        return singlePrice ? 0 : nav();
    }

    function mintPrice() public view returns (uint256) {
        if (pricesForced) return forcedMintPrice;

        return singlePrice ? nav() : (nav() * (_WAD + premium)) / _WAD;
    }

    function maxRedeemNow() public view returns (uint256) {
        uint256 _balance = _QUOTE.balanceOfSelf();

        return _balance < exitCap ? _balance : exitCap;
    }

    /// @notice NAV per token, WAD.
    function nav() public view returns (uint256) {
        return (assets * _WAD) / _TOKEN.totalSupply();
    }
}
