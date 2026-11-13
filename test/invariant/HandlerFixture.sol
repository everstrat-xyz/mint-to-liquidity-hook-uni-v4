// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookFixture} from "../utils/HookFixture.sol";
import {HookHandler} from "./HookHandler.sol";

/**
 * @notice The hook fixture plus a funded handler, shared by the invariant suite and its regressions.
 */
abstract contract HandlerFixture is HookFixture {
    uint256 internal constant HANDLER_TOKENS = 900_000e18;
    uint256 internal constant HANDLER_QUOTE_UNITS = 9_000_000;
    uint256 internal constant HANDLER_NATIVE_BALANCE = 100_000_000 ether;

    HookHandler internal handler;

    function setUp() public virtual override {
        super.setUp();

        handler = new HookHandler(
            HookHandler.Setup({
                manager: manager,
                swapRouter: swapRouter,
                modifyLiquidityRouter: modifyLiquidityRouter,
                hook: hook,
                issuer: issuer,
                token: token,
                quoteToken: quoteToken,
                poolKey: poolKey,
                beneficiary: beneficiary,
                quoteUnit: _quoteUnit(),
                liquidityUnit: _defaultLiquidity() / 10_000
            })
        );

        // Transfers, not mints: the supply and so the NAV stay as the fixture set them.
        token.transfer(address(handler), HANDLER_TOKENS);
        if (_quoteIsNative()) vm.deal(address(handler), HANDLER_NATIVE_BALANCE);
        else quoteToken.transfer(address(handler), HANDLER_QUOTE_UNITS * _quoteUnit());
    }
}
