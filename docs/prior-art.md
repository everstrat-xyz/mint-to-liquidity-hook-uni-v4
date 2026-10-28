# Prior art

Existing Uniswap v4 hooks that overlap with the Mint-to-Liquidity hook, and how this hook differs. Research done in October 2026.

## Summary

We found no hook that combines all three parts of this design:

1. an ordinary concentrated-liquidity pool where LPs and price discovery stay in place;
2. the issuer as the market of last resort, filling swaps at its mint price (ceiling) and redemption price (floor) only when the pool can't fill in band;
3. the protocol, not MEV bots, keeping the arbitrage profit when the pool is pulled back into the band.

Each part exists elsewhere on its own. Routing a swap through an issuer's mint or redeem is already standard, including in hooks Uniswap Labs ships. The novelty is the hybrid: issuer-backed edges around a live market. It also handles two things issuer-backed tokens commonly have and existing hooks don't: different mint and redemption prices (fees, premiums), and redemptions that can't always be paid at once (withdrawal queues, cooldowns, delayed settlement).

## 1. Wrapper and vault conversion hooks

These turn every swap into a mint or redeem at the issuer's rate, with no LPs. They are the same mechanism as this hook's direct fills (README §3), minus the band and the market.

| Hook | Who | What it does |
| --- | --- | --- |
| [`WETHHook`](https://github.com/Uniswap/v4-hooks-public/blob/main/src/WETHHook.sol) | Uniswap Labs | ETH ↔ WETH wrapping inside a swap |
| [`WstETHHook`](https://github.com/Uniswap/v4-hooks-public/blob/main/src/WstETHHook.sol) | Uniswap Labs | stETH ↔ wstETH wrapping inside a swap |
| [`BaseTokenWrapperHook`](https://github.com/Uniswap/v4-hooks-public/blob/main/src/base/BaseTokenWrapperHook.sol) | Uniswap Labs | Shared base for the two above |
| [`WstETHRoutingHook`](https://github.com/Uniswap/v4-hooks-public/blob/main/src/WstETHRoutingHook.sol) | Uniswap Labs | Stand-in for `WstETHHook` that lets the v4 Quoter simulate a wrap without executing it |
| [`ERC4626Hook`](https://github.com/Uniswap/hooklist/pull/7001) | unknown | Ethereum mainnet, `0x9b61e672113962daacb798707da72d219fcbc088`. Swaps between a vault's asset and its shares through `deposit`/`redeem`/`mint`/`withdraw`, using `beforeSwap` plus a return delta only |
| [`Generic4626Router`](https://github.com/Uniswap/hooklist/pull/4641) | unknown | Unichain. Routes swaps through any ERC-4626 vault and blocks liquidity adds |
| `PhiEthHooks` ([hooklist #9373](https://github.com/Uniswap/hooklist/pull/9373)) | unknown | Base. 1:1 ETH ↔ phiEth through a custom curve, liquidity blocked |

**How we differ:**

- **They replace the market.** Every swap is a conversion: no LPs, no fees for LPs, no price discovery. This hook keeps the pool and only calls the issuer at the edges.
- **One rate vs. a band.** A conversion hook has one rate. When an issuer charges mint or redemption fees, or mints at a premium, its two prices differ, and that gap is where a market can trade.
- **Immediate exits only.** They assume every redemption is paid in the same transaction. LSTs with withdrawal queues, stablecoins with cooldowns and RWA tokens with delayed settlement can't promise that. This hook caps floor fills at what the issuer can pay out now and lets the floor go soft beyond it.

**Why not just use `ERC4626Hook`?** For a vault that only needs conversion, it's the right tool, and we should say so. For our case it falls short in four ways:

1. **It only fits ERC-4626 vaults.** In ERC-4626 the vault contract *is* the share token. Tokens issued by a separate contract (EVE, most LSTs, most stablecoins) would need a wrapped copy, which splits their liquidity.
2. **Routers can't call it as is.** According to the hooklist review, it reads `(recipient, payer)` from `hookData` and pulls tokens from the payer directly. Standard routers and aggregators don't send that, so it needs custom integration.
3. **It converts between the vault's asset and its shares.** There's no native-ETH leg unless the vault's asset is WETH.
4. **It assumes synchronous redemption**, as ERC-4626 `redeem` does.

Our ERC-4626 adapter (production scope) would let the same vaults get a market on top of conversion.

**What to reuse:** `WstETHRoutingHook` solves a real problem this hook has too. The v4 Quoter can't simulate a hook that mints, so routers can't quote the pool unless a simulation path exists.

## 2. Reference-price hooks that use fees

These defend a target price with fees rather than issuance.

| Hook | Who | What it does |
| --- | --- | --- |
| [StablePair Hook](https://developers.uniswap.org/docs/protocols/uniswap-labs-hooks) | Uniswap Labs (official) | Concentrates liquidity around a reference rate for pegged pairs (USDC/USDT, USDC/USDG). Trades away from the peg pay no fee, and trades back towards it go through a Dutch auction. Pool creation is permissioned, and the hook is upgradeable through governance |
| `UsdcWstGbpHook` ([hooklist #820](https://github.com/Uniswap/hooklist/pull/820)) | unknown | Ethereum. Dynamic LP fee based on how far the pool is from Chainlink GBP/USD combined with wstGBP's NAV |

**How we differ:** these hooks make trading back to the reference price more profitable but still need outside arbitrageurs and outside liquidity. This hook does the correcting trade itself, by minting or redeeming through the issuer, and keeps the profit for the protocol. StablePair is the natural comparison to cite: band keeping by fees vs. band keeping by issuance.

## 3. Token launch hooks

These create a market for a brand-new token, which is the same problem as this hook's pitch. They work without an issuer that redeems, so the token has no NAV to anchor its price.

| Hook | What it does |
| --- | --- |
| [Doppler](https://web3.bitget.com/en/academy/what-is-doppler-protocol-on-uniswap-v4-powering-next-gen-token-launches-in-defi) | Price discovery for launches with Dutch-auction and bonding-curve mechanics. Zora uses its multi-curve liquidity positioning |
| [Flaunch](https://uniswapfoundation.org/blog/builder-stories-how-flaunch-is-revolutionizing-liquidity-with-hooks) | Memecoin launchpad on Base. Fixed-price window, then the open market; trading fees go to the creator |
| [Zora coin hook](https://docs.zora.co/coins/contracts/hook) | One hook for all Zora coins: pool setup, fees, automated liquidity |
| `Floor` ([hooklist #7009](https://github.com/Uniswap/hooklist/pull/7009)) | A token that is its own hook. Custom curve `(x − F) · y = k`, where the floor `F` rises by 1% of every swap's input; no LPs |
| Bonding-curve hooks ([#8530](https://github.com/Uniswap/hooklist/pull/8530), [#8657](https://github.com/Uniswap/hooklist/pull/8657), [#1876](https://github.com/Uniswap/hooklist/pull/1876)) | Launch curves that set every price in the hook, often migrating to a normal pool later |

**How we differ:** launch hooks run a pricing curve of their own. This hook never prices anything and borrows the issuer's prices instead, so it suits tokens with real backing (vaults, LSTs, NAV tokens). A mint-only bonding-curve token can still use it, with a ceiling and no floor.

## 4. Liquidity sourced from vaults

| Hook | What it does |
| --- | --- |
| [EulerSwap](https://docs.euler.finance/developers/euler-swap) | Each LP is its own pool, backed by Euler v2 vault deposits. Swaps can borrow against the vault (just-in-time liquidity) and are reachable through Uniswap v4 routing |
| [Bunni v2](https://www.bankless.com/fr/read/bunni-v2-liquidity.md) | Pool liquidity can be parked in yield vaults (rehypothecation). Its current status is unclear: one source reports it closed |
| [VII Finance yield-harvesting hook](https://github.com/VII-Finance/yield-harvesting-hook) | Pays LPs lending yield on top of swap fees |

**How we differ:** these source liquidity from lending vaults. This hook sources it from the issuer's own mint and redemption.

## Building blocks

- [OpenZeppelin Uniswap Hooks](https://docs.openzeppelin.com/uniswap-hooks) provides `BaseCustomCurve`, `BaseCustomAccounting`, `BaseAsyncSwap` and dynamic-fee bases. `BaseCustomCurve` covers the delta pattern behind direct fills.
- Uniswap Labs [takes requests](https://developers.uniswap.org/docs/protocols/uniswap-labs-hooks) for custom asset-class hooks, so an issuer-band hook may overlap with their roadmap.

## Method and limits

- We checked Uniswap Labs' hook docs and `Uniswap/v4-hooks-public`, the OpenZeppelin and `v4-periphery` repositories, and the [Uniswap hooklist](https://github.com/Uniswap/hooklist) searched by keyword ("NAV", "mint", "redeem"). The hooklist has thousands of entries, so this isn't exhaustive.
- Hooklist descriptions are generated by a review bot from the verified source. We didn't read `ERC4626Hook`'s source, and its pricing isn't documented.
- StablePair's fee details come from news coverage ([crypto.news](https://crypto.news/uniswap-targets-arbitrage-value-with-new-v4-hook/), [Cryptometer](https://www.cryptometer.io/news/uniswap-launches-stablepair-hook-to-help-liquidity-providers-capture-more-arbitrage-value/)), not Uniswap's own docs.
- Launch-hook descriptions come from early 2025 coverage and project docs; their details may have changed.
