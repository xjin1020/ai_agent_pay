# AgentEscrowV4

Trustless payment escrow with on-chain reputation for agent-to-agent work. Built for the [SYNTHESIS](https://synthesis.md) hackathon — **Agents that Pay** track.

## The Problem

> Your agent moves money on your behalf. But how do you know it did what you asked? There's no transparent way to scope what it can spend, verify that it spent correctly, or guarantee settlement without a middleman.

## The Solution

AgentEscrowV4 provides trustless, on-chain payment infrastructure for AI agents:

- **Scoped spending**: buyer locks exact amount in escrow — agent can't overspend
- **Verifiable delivery**: seller submits `workHash` (SHA256 of deliverable) as proof
- **No middleman**: auto-release after dispute window — no human needed for happy path
- **On-chain reputation**: 1-5 star ratings build seller trust scores over time
- **Fair disputes**: partial arbitration (basis points split), not binary winner-takes-all
- **Anti-censorship**: arbiter timeout guarantees funds are never permanently locked

## Live Demo (Polygon Mainnet)

First real escrow job completed on-chain — full lifecycle in 4 transactions:

| Step | TX | Details |
|------|----|---------| 
| **Create Job** | [`0x27c946...`](https://polygonscan.com/tx/0x27c94676f85f07d3bdf902a8cfdadbb38b3957151fb04fc038617c1821ef2137) | 1 USDC.e locked, 6h dispute window |
| **Submit Work** | [`0x4a102c...`](https://polygonscan.com/tx/0x4a102cc6385db5797f5f6bf4e0edca22ce4160ec3bf583f6991f43ceddfdee59) | Seller submits work hash proof |
| **Release** | [`0x2daa12...`](https://polygonscan.com/tx/0x2daa1237f3a0d3a4b4312d3c6c3476b4df8912fc264901f02c2ab26c95a80ef6) | Seller receives 0.995 USDC.e, 0.005 fee |
| **Rate** | [`0x58deba...`](https://polygonscan.com/tx/0x58deba1feca310bbf90fde0b704c9ba26da9d4a0164411acfd9966f421f3e43c) | 5-star on-chain reputation ⭐⭐⭐⭐⭐ |

## Quick Start (TypeScript SDK)

```typescript
import { AgentEscrow } from "@ai-agent-pay/sdk";
import { ethers } from "ethers";

const signer = new ethers.Wallet(PRIVATE_KEY, provider);
const escrow = new AgentEscrow(signer); // Polygon mainnet

// Buyer creates job
const jobId = await escrow.createJob({
  seller: "0xSellerAgent",
  token:  AgentEscrow.TOKENS.USDC,
  amount: 10_000_000n,  // 10 USDC
  deadline: Math.floor(Date.now() / 1000) + 7 * 86400,
});

// Seller submits work
await escrow.submitWork(jobId, AgentEscrow.hashDeliverable("ipfs://Qm..."));

// Buyer releases → seller gets paid (0.5% protocol fee)
await escrow.release(jobId);

// Buyer rates seller
await escrow.rateJob(jobId, 5); // ⭐⭐⭐⭐⭐

// Check reputation
const stats = await escrow.getSellerStats(sellerAddress);
// { completedJobs: 12, disputedJobs: 1, avgRatingX100: 420, ratingCount: 10 }
```

## V4 Features

### On-Chain Reputation
Buyers rate sellers 1-5 stars after job completion. Ratings are stored on-chain and queryable by any agent — build trust before you transact.

```solidity
function rateJob(uint256 jobId, uint8 rating) external;        // buyer only, once per job
function sellerRating(address) view returns (uint256 avgX100, uint256 count);
function sellerStats(address) view returns (uint256 completed, uint256 disputed, uint256 avgX100, uint256 count);
```

### Protocol Fee
Configurable fee (default 0.5%, max 5%) deducted on release. Sustains the protocol.

### Arbiter Timeout
If a dispute sits unresolved past `arbiterTimeoutSeconds` (default 7 days), **anyone** can force-release to the seller. No funds locked forever, no arbiter censorship.

### Partial Arbitration (V3+)
Arbiter splits funds by basis points — not binary:
```solidity
resolveDispute(jobId, 7000); // 70% seller, 30% buyer (after fee)
```

### Dynamic Dispute Window (V3+)
6 hours to 7 days, set per-job at creation:
```solidity
createJob(seller, token, amount, deadline, milestones, 6 hours);  // fast micro-task
createJob(seller, token, amount, deadline, milestones, 7 days);   // big contract
```

### Milestone Payments
Split large jobs into chunks. Accounting is correct (no double-pay bug from V2).

## Deployed Contracts (Polygon Mainnet)

| Contract | Address | TX |
|---|---|---|
| **AgentEscrowV4** ✨ | [`0xf8a7e6b5Decfe1b6F57e3D16d8005BCa5Be88B6A`](https://polygonscan.com/address/0xf8a7e6b5Decfe1b6F57e3D16d8005BCa5Be88B6A) | [`0x3d746c...`](https://polygonscan.com/tx/0x3d746c3835dfa1af9285726afcb81ecf32aba36667c00973f2cd8ab12f024a84) |
| AgentEscrowV2Fixed | [`0x9C8eefb386C395089D7906C67b48A3fd5ca14B9c`](https://polygonscan.com/address/0x9C8eefb386C395089D7906C67b48A3fd5ca14B9c) | [`0x700033...`](https://polygonscan.com/tx/0x7000334d05fe02ad378453724210bc33a9b2035f33aa012a4dde483b28d16b76) |

| Config | Value |
|---|---|
| **Network** | Polygon (chain 137) |
| **Arbiter** | `0xe75895c6B674bcdBe910ed4d33fabCd6689290Fb` |
| **Fee Collector** | `0xe75895c6B674bcdBe910ed4d33fabCd6689290Fb` |
| **Protocol Fee** | 0.5% (50 bps) |
| **Arbiter Timeout** | 7 days |

## Frontend Demo

Interactive web UI for interacting with the deployed contract. Connect your wallet and try it.

```bash
cd frontend && npm install && npm run dev
# → http://localhost:5173
```

**Features:**
- 🔗 **Wallet Connect** — MetaMask, auto-switches to Polygon network
- 📊 **Live Dashboard** — Job count, protocol fee, arbiter timeout from on-chain data
- ➕ **Create Job** — Token dropdown (USDC/USDCe/USDT/WETH), amount, deadline picker, dispute window slider (6h–7d), optional milestones
- 🔍 **Job Viewer** — Lookup by ID, full details (status, buyer, seller, amounts, deadline, work hash). Context-aware action buttons: Submit Work, Release, Dispute, Refund, Auto Release, Rate (1–5 ⭐)
- 👤 **Reputation Lookup** — Star visualization, avg rating, completed/disputed counts, success rate

**Tech stack:** Vite + React + TypeScript + Tailwind CSS v4 + ethers.js v6

## Contracts

| File | Description |
|------|-------------|
| `src/AgentEscrowV4.sol` | ✨ Latest — reputation + protocol fee + arbiter timeout |
| `src/AgentEscrowV3.sol` | Partial arbitration + dynamic dispute window |
| `src/AgentEscrowV2Fixed.sol` | All V2 bugs fixed, binary arbitration |
| `src/AgentEscrowV2.sol` | Original with critical bug (reference only) |
| `sdk/` | TypeScript SDK (v0.4.0) |
| `frontend/` | React demo UI |

## Tests

```bash
forge test -v
```

| Test file | Tests | Result |
|-----------|-------|--------|
| `test/AgentEscrowV4.t.sol` | 17 + 256 fuzz | ✅ all pass |
| `test/AgentEscrowV3.t.sol` | 17 + 256 fuzz | ✅ all pass |
| `test/AgentEscrowV2Fixed.t.sol` | 15 | ✅ all pass |
| `test/AgentEscrowV2.t.sol` | 32 | ✅ 31 pass, 1 intentional fail (proves critical bug) |

## Security

Full audit report: [`SECURITY_AUDIT.md`](./SECURITY_AUDIT.md)

All critical and medium issues from V2 are fixed in V4:
- ✅ Milestone double-payment drain
- ✅ Disputed funds locked forever → partial arbitration + arbiter timeout
- ✅ buyer == seller validation
- ✅ SafeTransfer library for USDT compatibility

## Architecture

```
Buyer                    Contract                  Seller
  │                         │                        │
  │── createJob(amount) ───→│                        │
  │   (tokens locked)       │                        │
  │                         │←── submitWork(hash) ───│
  │                         │   (dispute window opens)│
  │                         │                        │
  ├── release() ───────────→│── pay seller ─────────→│
  │   OR                    │── fee → collector      │
  ├── dispute() ───────────→│                        │
  │                         │                        │
  │   Arbiter resolves:     │                        │
  │   resolveDispute(bps)──→│── split by bps ───────→│
  │                         │                        │
  │   OR timeout (7d):      │                        │
  │   arbiterTimeoutRelease→│── pay seller ─────────→│
  │                         │                        │
  │── rateJob(1-5) ────────→│── update reputation    │
```

## License

MIT
