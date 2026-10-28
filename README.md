# Mint-to-Liquidity Hook (Uniswap v4)

A generic Uniswap v4 hook that gives any **mintable token** a working market from its first block. The token's issuer already knows its price: what a new token costs to mint and what one redeems for. The hook turns those two quotes into the pool's market. Buys can always fill at the mint price and sells at the redemption price, so no one has to seed the pool or run a market maker. LPs who join later trade inside that band and tighten the spread. The hook mints and redeems through the issuer to keep the pool inside the band, and the arbitrage profit goes to the protocol instead of to MEV bots.

> Status: **prototype**. It exists to measure how hard the production hook is to build. It is unaudited and not for mainnet use.

## 1. Problem

A new token needs a market, and a market needs liquidity. Today, minting a token and providing its liquidity are two separate steps, done by different people in different contracts:

1. A user deposits into the issuer's contract to mint.
2. Someone else pairs that token with a quote asset (ETH, USDC, …) and deposits both into an AMM pool, then keeps the range in place.

Until step 2 happens, the token has no market. Even once it has one, the issuer and the pool price the same token independently. Outside arbitrageurs close the gap when they bother to and keep the profit, while buyers overpay and sellers get too little.

### Which tokens this is for

Any token whose issuer will mint and redeem it onchain: vault shares, liquid staking tokens, yield-bearing stablecoins, RWA and NAV tokens, bonding-curve tokens. Two features are common across them, and existing hooks handle neither (see [prior art](docs/prior-art.md)):

- **Two prices, not one.** Mint and redemption rarely happen at the same price. Mint fees, redemption fees, entry and exit fees on vaults, and issuance premiums all open a gap between them. The hook treats that gap as a band and lets the market trade inside it.
- **Exits that can't always be paid at once.** LSTs have withdrawal queues, some stablecoins have cooldowns, and RWA tokens settle days later. The hook only redeems what the issuer can pay out immediately, so the floor holds up to that capacity and is soft beyond it.

### First integration: Everstrat

[Everstrat](https://everstrat.xyz) is an ETH yield protocol on Ethereum mainnet. Users deposit ETH and mint EVE, a token backed by the protocol's book, which is **100% Uniswap v3 liquidity**. Everstrat earns its yield by providing liquidity to Uniswap, yet its own token has no reliable liquidity. EVE has both features above: it mints at a premium over NAV and redeems at NAV, and redemptions beyond the protocol's free ETH are queued.

What the two-step model costs, measured on Everstrat:

- **Value leaks to arbitrageurs.** 21 of 38 mints could be arbitraged against the pool right after, by up to 26.6%.
- **Two quotes for one token.** The issuer and the pool price EVE differently, and nothing keeps them aligned.

## 2. Design summary

The pool is an **ordinary concentrated-liquidity pool**. The hook adds no pricing of its own: it reads the band from the issuer and does two things with it.

1. **Market of last resort.** When the pool can't fill a swap at a price inside the band, the hook fills it directly from the issuer: buys are minted at the ceiling and sells are redeemed at the floor. On day one, with no LPs, this *is* the market.
2. **Band keeper.** Whenever the pool price leaves the band, the hook mints or redeems through the issuer and trades the price back to the band edge in the same transaction.

```
                  ┌──────────── ceiling = issuer mint price ────────────┐
pool price above  │  hook mints at the ceiling, sells into the pool      │  price pushed down to ceiling
                  │                                                      │
inside the band   │  LPs trade and earn fees; with no LPs, the hook      │
                  │  fills buys at the ceiling and sells at the floor    │
                  │                                                      │
pool price below  │  hook buys from the pool, redeems at the floor       │  price pushed up to floor
                  └──────────── floor = issuer redemption price ─────────┘
```

- **One step.** A token gets a market by deploying an adapter (§5) and registering a pool. No seed liquidity, no market maker, no range management.
- **The issuer is the source of truth.** The hook only trades with the issuer at the issuer's own quotes and under the issuer's own checks, so it takes on no pricing risk the issuer doesn't already accept.
- **No capital needed.** v4's flash accounting lets the hook swap first and settle with the issuer afterwards, all within one `unlock`.
- **Profit stays with the protocol.** The spread between an out-of-band pool price and the band edge goes to the issuer's beneficiary.
- **LPs are optional.** Liquidity is permissionless. LPs who join earn normal v4 fees by quoting inside the band, which tightens the spread over time.

**How it relates to conversion hooks.** Swapping straight through an issuer already exists: Uniswap Labs' WETH and wstETH hooks, and ERC-4626 hooks such as `ERC4626Hook`. Those turn the pool into a converter, with no LPs and one rate. If a token only needs conversion, they are the right tool, and this hook can act as one too: an issuer that sets `redeemPrice() = 0` gets a single price for buys and sells (§5). Beyond that, it covers the case where the token should have a market: LPs and price discovery between the issuer's two prices, with the issuer filling swaps only at the edges. See [docs/prior-art.md](docs/prior-art.md).

## 3. Direct fills (market of last resort)

In `beforeSwap`, after the drift rebalance (§4), the hook fills the swap itself when either of these holds:

- **the pool price is at the band edge in the swap's direction:** a buy at the ceiling, or a sell at the floor;
- **the pool has no active liquidity.**

Otherwise the curve fills the swap as usual, and `afterSwap` corrects any overshoot (§4).

A direct fill returns a `BeforeSwapDelta` (custom-curve pattern), so the v4 curve is skipped for the amount the hook fills.

| Direction | Price | Settlement |
| --- | --- | --- |
| Buy (quote → token) | ceiling `C` | `take` quote → `adapter.mint` → pay token to the PoolManager |
| Sell (token → quote) | floor `F` | `take` token → `adapter.redeem` → pay quote to the PoolManager |

"Pay to the PoolManager" is `settle{value}` for native ETH, and `sync` → transfer → `settle` for an ERC-20.

Exact-input and exact-output are both supported, and rounding always favours the issuer. A sell larger than the issuer's immediate exit capacity (`maxRedeemNow()`) is filled up to that capacity, and the rest goes to the curve. A token with no exit capacity (`maxRedeemNow() = 0`) gets direct buys only.

## 4. Band keeping (rebalancing)

A **rebalance** moves the pool price back to the nearest band edge. It runs:

- in `beforeSwap`, to correct drift since the last trade (the issuer's value moves while the pool sits idle), so the swapper trades in band;
- in `afterSwap`, to correct the swapper's own push past an edge;
- from `rebalance(PoolKey)`, which anyone can call (keeper backstop).

The band is read from the adapter once per transaction and cached in transient storage, so `beforeSwap` and `afterSwap` share a single read.

**Price orientation.** v4 orders a pool's currencies by address, and `sqrtPriceX96 = √(currency1 per currency0)`. Depending on the quote currency, the token can be either side (native ETH, address zero, is always `currency0`). `BandMath` converts a token price `p` (quote per token) into a sqrtPrice for both cases:

| Token is | sqrtPriceX96 | Ceiling is the |
| --- | --- | --- |
| `currency1` (e.g. quote = ETH) | `√(1/p) × 2⁹⁶` | lower sqrtPrice bound |
| `currency0` | `√p × 2⁹⁶` | upper sqrtPrice bound |

### 4.1 Above the ceiling (pool price > mint price `C`)

1. The hook swaps token → quote in the pool, with `sqrtPriceLimitX96` at `C`. The swap stops exactly at the ceiling and leaves the hook owing `t` tokens and owed `q` quote.
2. `take` quote `q` from the PoolManager.
3. `adapter.mint(⌈t × C⌉, t)` returns at least `t` tokens.
4. Pay `t` tokens to the PoolManager.
5. Profit `q − ⌈t × C⌉` (> 0, because every unit sold above `C`) and any token dust go to the beneficiary.

### 4.2 Below the floor (pool price < redemption price `F`)

1. The hook swaps quote → token, exact output, with `sqrtPriceLimitX96` at `F`. The output is capped at `adapter.maxRedeemNow() / F`, so the redemption can always be paid out immediately.
2. `take` the `t` tokens bought.
3. `adapter.redeem(t, ⌊t × F⌋)` returns `⌊t × F⌋` quote.
4. Pay the `q` quote owed to the PoolManager.
5. Profit `⌊t × F⌋ − q` goes to the beneficiary.

Beyond the issuer's immediate exit capacity the floor is **soft**: the hook moves the price as far as that capacity allows and stops.

### 4.3 Never blocking a swap

The rebalance runs as an external self-call, `try this.rebalanceInternal(key) {} catch {}`. If the issuer reverts (paused, unhealthy, caps reached), the whole rebalance unwinds, including its pool swap, and the user's swap goes through as if the hook weren't there. The PoolManager never calls a hook for swaps the hook makes itself, so the rebalance swap can't recurse.

A direct fill (§3) works the same way: if the issuer can't fill, the swap falls through to the curve.

## 5. Issuer adapter

A token plugs in by deploying an adapter. The hook only ever talks to the adapter.

```solidity
interface IIssuerAdapter {
    function token() external view returns (IERC20);
    function quoteCurrency() external view returns (Currency);           // native ETH or any ERC-20
    function mintPrice() external view returns (uint256 _ceiling);        // quote per token, WAD
    function redeemPrice() external view returns (uint256 _floor);        // quote per token, WAD; 0 = same as mintPrice
    function maxRedeemNow() external view returns (uint256 _quoteOut);    // immediate exit capacity
    function mint(uint256 _quoteIn, uint256 _minTokens) external payable returns (uint256 _tokensOut);
    function redeem(uint256 _tokens, uint256 _minQuote) external returns (uint256 _quoteOut);
    function beneficiary() external view returns (address);
}
```

**Quote currency.** Each adapter names the asset its issuer mints and redeems against: native ETH for Everstrat, USDC for most stablecoin and RWA issuers, the underlying for an ERC-4626 vault. For native ETH, `mint` takes `msg.value == _quoteIn`; for an ERC-20, the adapter pulls `_quoteIn` from the hook, which approves it at registration. `redeem` pays the quote to the caller.

**Units.** Prices are WAD-scaled ratios of raw base units (`quote units × 1e18 / token units`), so `quote = tokens × price / 1e18` holds whatever the two tokens' decimals are.

**Single price.** An issuer that mints and redeems at the same price returns `redeemPrice() = 0`, and the hook sets the floor equal to the ceiling. The band collapses to one price, so every swap is filled by the issuer at that price and the pool works as a converter, like the conversion hooks in §2. Any LP liquidity in the pool is arbitraged back to that price.

A token with mint but no redemption (such as a mint-only bonding curve) returns `maxRedeemNow() = 0`. The hook never redeems, so the token gets a ceiling only.

**The anchor rule:** the adapter's prices must never read the pool this hook guards.

### 5.1 Everstrat adapter

| Adapter call | Everstrat AMM |
| --- | --- |
| `mintPrice()` | `evePremiumPriceInETH()` |
| `redeemPrice()` | `eveBasePriceInETH()` |
| `maxRedeemNow()` | `freeBalance()` |
| `quoteCurrency()` | native ETH |
| `mint` | `enter{value: _quoteIn}(_minTokens)` |
| `redeem` | `exit(_minQuote, _tokens, tolerance)`; reverts if it returns a non-zero `batchId` (a queued exit) |

Setup on the Everstrat side, through the 48h timelock:

- whitelist the adapter (`AMM.enter` checks `msg.sender`);
- no new roles are needed. The adapter is an ordinary AMM user, and it approves the AMM so `burnFrom` can pull its EVE.

## 6. Contracts

Following the `everstrat-xyz/contracts` conventions (interfaces hold events, errors and structs; errors are prefixed with the contract name; `_camelCase` arguments; named imports).

| File | Role |
| --- | --- |
| `src/MintToLiquidityHook.sol` | Pool registration, band reads, direct fills, rebalance, profit sweep |
| `src/libraries/BandMath.sol` | Price ↔ sqrtPriceX96 conversion, fill amounts and rounding, fuzzed in isolation |
| `src/interfaces/IIssuerAdapter.sol` | What an issuer implements (§5) |
| `src/interfaces/IMintToLiquidityHook.sol` | Hook structs, events and errors |
| `src/adapters/EverstratAMMAdapter.sol` | §5.1 |
| `test/mocks/MockIssuer.sol` | Reference issuer with a premium-over-NAV mint and a NAV redeem |

The hook extends OpenZeppelin's audited `BaseHook` (`OpenZeppelin/uniswap-hooks` v1.2.1) on `v4-core`, and is compiled with solc `0.8.26` (PoolManager's pinned version).

### 6.1 Hook permissions

| Callback | Enabled | Why |
| --- | --- | --- |
| `beforeInitialize` | yes | Only pools registered with an adapter, pairing `adapter.token()` with `adapter.quoteCurrency()` |
| `beforeSwap` + `beforeSwapReturnDelta` | yes | Drift rebalance, then direct fill when the pool can't fill in band |
| `afterSwap` | yes | Rebalance the user's push past an edge |
| everything else | no | Liquidity is permissionless; LP fees are normal v4 fees |

### 6.2 Pool registration

`registerPool(IIssuerAdapter _adapter, uint24 _fee, int24 _tickSpacing)` builds the key from the adapter's token and quote currency, binds the pool to the adapter and initialises it at the band's midpoint. Only the adapter's owner can call it, so nobody can attach an issuer to a pool the issuer didn't authorise.

## 7. Safety rails

| Rail | Behaviour |
| --- | --- |
| Issuer failure | Rebalance and direct fill are skipped; the user's swap goes to the curve (§4.3) |
| Queued exit | The adapter reverts, so the redemption is skipped; the hook never holds a queue position |
| Exit capacity | Floor buys and direct sells are capped at `maxRedeemNow()` |
| Invalid band | `mintPrice() == 0` or `redeemPrice() > mintPrice()` → hook stands aside, event emitted |
| Leftover balances | Hook ends every transaction holding no quote or tokens; profit and dust are swept to `beneficiary()` |
| Foreign pools | `beforeInitialize` reverts for unregistered keys |

## 8. Invariants (Foundry)

1. After a rebalance that ran, the pool price is inside `[floor, ceiling]` (one-tick tolerance), or at the floor-side capacity limit.
2. A direct fill never prices a buy below the ceiling or a sell above the floor.
3. A rebalance never loses money: profit ≥ 0 in the quote currency.
4. The hook holds no quote or tokens between transactions.
5. The hook never causes a queued exit.
6. No user swap reverts because of the hook.
7. The issuer's redemption price per token never decreases as a result of a hook trade (mints happen at the ceiling, burns at the floor).

## 9. Prototype scope

**In:** the hook, `BandMath`, the adapter interface, `MockIssuer`, unit tests for every branch, fuzz tests for `BandMath`, invariant tests (§8), exact-input and exact-output in both directions through the v4 test router (with and without LPs), and a mainnet-fork test of `EverstratAMMAdapter` against the deployed AMM.

**Out (production work):**

- Gas profiling and a cheaper trigger, e.g. skipping the issuer read when the pool price is well inside the last known band
- Rebating the out-of-band surplus to the swapper (`afterSwapReturnDelta`) instead of the protocol
- An ERC-4626 adapter
- Router and aggregator integration, audit

## 10. Development

```bash
forge build
forge test
forge fmt --check src/ test/
```

## 11. Open questions

- **Where Everstrat's profit goes.** To the Controller (it accrues to NAV for every holder) or to the AMM (it adds immediate exit capacity)?
- **Rebate or keep.** The swapper who pushes past an edge overpays for that portion. Should the hook keep the surplus, or refund it so the swapper gets the price they would have got by splitting the order with the issuer?
- **Existing liquidity.** EVE's current pool keeps being arbitraged by bots. Does liquidity migrate to the hooked pool, or should both exist?
- **Gas per swap.** Reading Everstrat's NAV is expensive. How much does that cost the pool in routing?

## License

MIT
