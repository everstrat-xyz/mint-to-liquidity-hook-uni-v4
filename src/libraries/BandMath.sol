// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IMintToLiquidityHook} from "interfaces/IMintToLiquidityHook.sol";

/**
 * @title BandMath
 * @notice Converts issuer prices to pool sqrtPrices and sizes fills with rounding that favours the issuer.
 * @dev A price `p` is quote per token, WAD-scaled over raw base units. v4 orders a pool's currencies by
 * address and `sqrtPriceX96 = sqrt(currency1 per currency0) * 2^96`, so the token can be either side:
 *
 * - token is `currency0`: sqrtPrice = sqrt(p), and it rises with the token's price;
 * - token is `currency1`: sqrtPrice = sqrt(1 / p), and it falls as the token's price rises.
 */
library BandMath {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant WAD = 1e18;

    uint256 private constant _Q192 = 1 << 192;
    uint256 private constant _Q128 = 1 << 128;

    /// @dev Below this price `p * 2^192 / 1e18` fits in 256 bits, so the conversion keeps full precision.
    uint256 private constant _FULL_PRECISION_PRICE_BOUND = (1 << 64) * WAD;

    /// @dev Below this price `p * 2^128 / 1e18` fits in 256 bits.
    uint256 private constant _LOW_PRECISION_PRICE_BOUND = (1 << 128) * WAD;

    /*//////////////////////////////////////////////////////////////
                           PRICE CONVERSION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Converts a token price to the pool's sqrtPrice.
     * @param _price Quote per token, WAD.
     * @param _tokenIsCurrency0 Whether the token is the pool's `currency0`.
     * @return _sqrtPriceX96 The sqrtPrice, or zero when the price is zero or outside what a pool can hold.
     */
    function priceToSqrtPriceX96(uint256 _price, bool _tokenIsCurrency0) internal pure returns (uint160 _sqrtPriceX96) {
        if (_price == 0) return 0;

        uint256 _sqrt;
        if (!_tokenIsCurrency0) {
            // 1e18 * 2^192 < 2^252, so the product never overflows.
            _sqrt = Math.sqrt(Math.mulDiv(WAD, _Q192, _price));
        } else if (_price < _FULL_PRECISION_PRICE_BOUND) {
            _sqrt = Math.sqrt(Math.mulDiv(_price, _Q192, WAD));
        } else if (_price < _LOW_PRECISION_PRICE_BOUND) {
            _sqrt = Math.sqrt(Math.mulDiv(_price, _Q128, WAD)) << 32;
        } else {
            return 0;
        }

        // Strict bounds: the result is used as a swap price limit, which v4 requires to be inside them.
        if (_sqrt <= TickMath.MIN_SQRT_PRICE || _sqrt >= TickMath.MAX_SQRT_PRICE) return 0;

        // Safe: `_sqrt < MAX_SQRT_PRICE < 2^160`.
        return uint160(_sqrt);
    }

    /**
     * @notice Builds the band from the issuer's two quotes.
     * @param _ceiling The issuer's mint price, WAD.
     * @param _floor The issuer's redemption price, WAD. Zero means "same as the ceiling".
     * @param _tokenIsCurrency0 Whether the token is the pool's `currency0`.
     * @return _valid False when the ceiling is zero, the floor is above it, or either is not representable.
     * @return _band The band, meaningful only when `_valid`.
     */
    function buildBand(uint256 _ceiling, uint256 _floor, bool _tokenIsCurrency0)
        internal
        pure
        returns (bool _valid, IMintToLiquidityHook.Band memory _band)
    {
        if (_floor == 0) _floor = _ceiling;
        if (_ceiling == 0 || _floor > _ceiling) return (false, _band);

        _band.ceiling = _ceiling;
        _band.floor = _floor;
        _band.sqrtCeilingX96 = priceToSqrtPriceX96(_ceiling, _tokenIsCurrency0);
        _band.sqrtFloorX96 = priceToSqrtPriceX96(_floor, _tokenIsCurrency0);

        _valid = _band.sqrtCeilingX96 != 0 && _band.sqrtFloorX96 != 0;
    }

    /**
     * @notice The sqrtPrice of the band's midpoint, where a new pool is initialised.
     */
    function midSqrtPriceX96(IMintToLiquidityHook.Band memory _band, bool _tokenIsCurrency0)
        internal
        pure
        returns (uint160)
    {
        return priceToSqrtPriceX96(Math.average(_band.ceiling, _band.floor), _tokenIsCurrency0);
    }

    /*//////////////////////////////////////////////////////////////
                            BAND POSITION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Whether the pool prices the token strictly above the ceiling.
     */
    function isAboveCeiling(uint160 _sqrtPriceX96, IMintToLiquidityHook.Band memory _band, bool _tokenIsCurrency0)
        internal
        pure
        returns (bool)
    {
        return _tokenIsCurrency0 ? _sqrtPriceX96 > _band.sqrtCeilingX96 : _sqrtPriceX96 < _band.sqrtCeilingX96;
    }

    /**
     * @notice Whether the pool prices the token strictly below the floor.
     */
    function isBelowFloor(uint160 _sqrtPriceX96, IMintToLiquidityHook.Band memory _band, bool _tokenIsCurrency0)
        internal
        pure
        returns (bool)
    {
        return _tokenIsCurrency0 ? _sqrtPriceX96 < _band.sqrtFloorX96 : _sqrtPriceX96 > _band.sqrtFloorX96;
    }

    /**
     * @notice Whether the pool price sits at or past the band edge a swap is heading for:
     * the ceiling for a buy, the floor for a sell.
     */
    function isAtEdge(
        uint160 _sqrtPriceX96,
        IMintToLiquidityHook.Band memory _band,
        bool _tokenIsCurrency0,
        bool _isBuy
    ) internal pure returns (bool) {
        return _isBuy
            ? !_isBelow(_sqrtPriceX96, _band.sqrtCeilingX96, _tokenIsCurrency0)
            : !_isBelow(_band.sqrtFloorX96, _sqrtPriceX96, _tokenIsCurrency0);
    }

    /*//////////////////////////////////////////////////////////////
                             FILL AMOUNTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Quote worth `_tokens` at `_price`, rounded up. What a buyer pays for an exact token amount.
     */
    function quoteForTokensUp(uint256 _tokens, uint256 _price) internal pure returns (uint256) {
        return Math.mulDiv(_tokens, _price, WAD, Math.Rounding.Ceil);
    }

    /**
     * @notice Quote worth `_tokens` at `_price`, rounded down. What a seller receives for an exact token amount.
     */
    function quoteForTokensDown(uint256 _tokens, uint256 _price) internal pure returns (uint256) {
        return Math.mulDiv(_tokens, _price, WAD);
    }

    /**
     * @notice Tokens worth `_quote` at `_price`, rounded up. What a seller pays for an exact quote amount.
     */
    function tokensForQuoteUp(uint256 _quote, uint256 _price) internal pure returns (uint256) {
        return Math.mulDiv(_quote, WAD, _price, Math.Rounding.Ceil);
    }

    /**
     * @notice Tokens worth `_quote` at `_price`, rounded down. What a buyer receives for an exact quote amount.
     */
    function tokensForQuoteDown(uint256 _quote, uint256 _price) internal pure returns (uint256) {
        return Math.mulDiv(_quote, WAD, _price);
    }

    /*//////////////////////////////////////////////////////////////
                               PRIVATE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Whether sqrtPrice `_a` prices the token strictly below sqrtPrice `_b`.
     */
    function _isBelow(uint160 _a, uint160 _b, bool _tokenIsCurrency0) private pure returns (bool) {
        return _tokenIsCurrency0 ? _a < _b : _a > _b;
    }
}
