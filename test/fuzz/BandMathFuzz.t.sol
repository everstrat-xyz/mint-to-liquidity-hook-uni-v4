// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {BandMath} from "libraries/BandMath.sol";

import {IMintToLiquidityHook} from "interfaces/IMintToLiquidityHook.sol";

contract BandMathFuzzTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q192 = 1 << 192;

    /// @dev Prices from 1e-12 to 1e12 quote units per token unit: every pairing of 6- to 18-decimal
    /// currencies at realistic prices, with room to spare.
    uint256 internal constant MIN_PRICE = 1e6;
    uint256 internal constant MAX_PRICE = 1e30;
    uint256 internal constant MAX_AMOUNT = type(uint128).max;
    /// @dev The sqrt is rounded down, so a price read back from it can sit this far (relative, WAD) below.
    uint256 internal constant ROUND_TRIP_TOLERANCE = 1e9; // 1e-9

    /*//////////////////////////////////////////////////////////////
                           PRICE CONVERSION
    //////////////////////////////////////////////////////////////*/

    function testFuzz_PriceToSqrtPriceX96_RoundTrips(uint256 _price, bool _tokenIsCurrency0) public pure {
        _price = bound(_price, MIN_PRICE, MAX_PRICE);

        uint256 _sqrtPriceX96 = BandMath.priceToSqrtPriceX96(_price, _tokenIsCurrency0);
        assertGt(_sqrtPriceX96, 0, "representable");

        uint256 _ratioX192 = _sqrtPriceX96 * _sqrtPriceX96;
        uint256 _readBack =
            _tokenIsCurrency0 ? FullMath.mulDiv(_ratioX192, WAD, Q192) : FullMath.mulDiv(Q192, WAD, _ratioX192);

        // Reading back floors to a whole price unit, which is the larger error for very small prices.
        uint256 _tolerance = (_price * ROUND_TRIP_TOLERANCE) / WAD + 1;
        assertApproxEqAbs(_readBack, _price, _tolerance);
    }

    function testFuzz_PriceToSqrtPriceX96_FollowsTokenOrientation(uint256 _low, uint256 _high) public pure {
        _low = bound(_low, MIN_PRICE, MAX_PRICE - 1);
        _high = bound(_high, _low + 1, MAX_PRICE);

        // Token as currency0: sqrtPrice rises with the price. As currency1: it falls.
        assertLe(BandMath.priceToSqrtPriceX96(_low, true), BandMath.priceToSqrtPriceX96(_high, true));
        assertGe(BandMath.priceToSqrtPriceX96(_low, false), BandMath.priceToSqrtPriceX96(_high, false));
    }

    function testFuzz_PriceToSqrtPriceX96_ZeroOrUsableAsLimit(uint256 _price, bool _tokenIsCurrency0) public pure {
        uint160 _sqrtPriceX96 = BandMath.priceToSqrtPriceX96(_price, _tokenIsCurrency0);

        // Never reverts, and anything it returns is a price limit v4 accepts.
        if (_sqrtPriceX96 != 0) {
            assertGt(_sqrtPriceX96, TickMath.MIN_SQRT_PRICE);
            assertLt(_sqrtPriceX96, TickMath.MAX_SQRT_PRICE);
        }
    }

    function test_PriceToSqrtPriceX96_ZeroPrice() public pure {
        assertEq(BandMath.priceToSqrtPriceX96(0, true), 0);
        assertEq(BandMath.priceToSqrtPriceX96(0, false), 0);
    }

    function test_PriceToSqrtPriceX96_OneToOne() public pure {
        assertEq(BandMath.priceToSqrtPriceX96(WAD, true), 1 << 96);
        assertEq(BandMath.priceToSqrtPriceX96(WAD, false), 1 << 96);
    }

    /*//////////////////////////////////////////////////////////////
                                 BAND
    //////////////////////////////////////////////////////////////*/

    function testFuzz_BuildBand_Valid(uint256 _ceiling, uint256 _floor, bool _tokenIsCurrency0) public pure {
        _ceiling = bound(_ceiling, MIN_PRICE, MAX_PRICE);
        _floor = bound(_floor, MIN_PRICE, _ceiling);

        (bool _valid, IMintToLiquidityHook.Band memory _band) = BandMath.buildBand(_ceiling, _floor, _tokenIsCurrency0);

        assertTrue(_valid);
        assertEq(_band.ceiling, _ceiling);
        assertEq(_band.floor, _floor);

        // The midpoint and both edges are inside the band; a step beyond an edge is outside it.
        uint160 _mid = BandMath.midSqrtPriceX96(_band, _tokenIsCurrency0);
        assertFalse(BandMath.isAboveCeiling(_mid, _band, _tokenIsCurrency0));
        assertFalse(BandMath.isBelowFloor(_mid, _band, _tokenIsCurrency0));
        assertFalse(BandMath.isAboveCeiling(_band.sqrtCeilingX96, _band, _tokenIsCurrency0));
        assertFalse(BandMath.isBelowFloor(_band.sqrtFloorX96, _band, _tokenIsCurrency0));

        uint160 _pastCeiling = _tokenIsCurrency0 ? _band.sqrtCeilingX96 + 1 : _band.sqrtCeilingX96 - 1;
        uint160 _pastFloor = _tokenIsCurrency0 ? _band.sqrtFloorX96 - 1 : _band.sqrtFloorX96 + 1;
        assertTrue(BandMath.isAboveCeiling(_pastCeiling, _band, _tokenIsCurrency0));
        assertTrue(BandMath.isBelowFloor(_pastFloor, _band, _tokenIsCurrency0));

        // A buy is at its edge from the ceiling up, a sell from the floor down.
        assertTrue(BandMath.isAtEdge(_band.sqrtCeilingX96, _band, _tokenIsCurrency0, true));
        assertTrue(BandMath.isAtEdge(_pastCeiling, _band, _tokenIsCurrency0, true));
        assertTrue(BandMath.isAtEdge(_band.sqrtFloorX96, _band, _tokenIsCurrency0, false));
        assertTrue(BandMath.isAtEdge(_pastFloor, _band, _tokenIsCurrency0, false));
    }

    function testFuzz_BuildBand_ZeroFloorMeansSinglePrice(uint256 _ceiling, bool _tokenIsCurrency0) public pure {
        _ceiling = bound(_ceiling, MIN_PRICE, MAX_PRICE);

        (bool _valid, IMintToLiquidityHook.Band memory _band) = BandMath.buildBand(_ceiling, 0, _tokenIsCurrency0);

        assertTrue(_valid);
        assertEq(_band.floor, _ceiling);
        assertEq(_band.sqrtFloorX96, _band.sqrtCeilingX96);
    }

    function testFuzz_BuildBand_FloorAboveCeiling(uint256 _ceiling, uint256 _floor, bool _tokenIsCurrency0)
        public
        pure
    {
        _ceiling = bound(_ceiling, MIN_PRICE, MAX_PRICE - 1);
        _floor = bound(_floor, _ceiling + 1, MAX_PRICE);

        (bool _valid,) = BandMath.buildBand(_ceiling, _floor, _tokenIsCurrency0);

        assertFalse(_valid);
    }

    function testFuzz_BuildBand_ZeroCeiling(uint256 _floor, bool _tokenIsCurrency0) public pure {
        (bool _valid,) = BandMath.buildBand(0, _floor, _tokenIsCurrency0);

        assertFalse(_valid);
    }

    /*//////////////////////////////////////////////////////////////
                             FILL AMOUNTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_BuyExactOutput_IssuerMintCoversIt(uint256 _tokens, uint256 _price) public pure {
        _price = bound(_price, MIN_PRICE, MAX_PRICE);
        _tokens = bound(_tokens, 1, MAX_AMOUNT);

        // The buyer pays the rounded-up quote; an issuer minting `floor(quote / price)` covers the tokens.
        uint256 _quote = BandMath.quoteForTokensUp(_tokens, _price);

        assertGe(BandMath.tokensForQuoteDown(_quote, _price), _tokens);
        assertGe(_quote * WAD, _tokens * _price, "priced below the ceiling");
    }

    function testFuzz_BuyExactInput_NeverBelowCeiling(uint256 _quote, uint256 _price) public pure {
        _price = bound(_price, MIN_PRICE, MAX_PRICE);
        _quote = bound(_quote, 1, MAX_AMOUNT);

        uint256 _tokens = BandMath.tokensForQuoteDown(_quote, _price);

        assertGe(_quote * WAD, _tokens * _price, "priced below the ceiling");
    }

    function testFuzz_SellExactOutput_IssuerRedemptionCoversIt(uint256 _quote, uint256 _price) public pure {
        _price = bound(_price, MIN_PRICE, MAX_PRICE);
        _quote = bound(_quote, 1, MAX_AMOUNT);

        // The seller pays the rounded-up tokens; an issuer paying `floor(tokens * price)` covers the quote.
        uint256 _tokens = BandMath.tokensForQuoteUp(_quote, _price);

        assertGe(BandMath.quoteForTokensDown(_tokens, _price), _quote);
        assertLe(_quote * WAD, _tokens * _price, "priced above the floor");
    }

    function testFuzz_SellExactInput_NeverAboveFloor(uint256 _tokens, uint256 _price) public pure {
        _price = bound(_price, MIN_PRICE, MAX_PRICE);
        _tokens = bound(_tokens, 1, MAX_AMOUNT);

        uint256 _quote = BandMath.quoteForTokensDown(_tokens, _price);

        assertLe(_quote * WAD, _tokens * _price, "priced above the floor");
    }
}
