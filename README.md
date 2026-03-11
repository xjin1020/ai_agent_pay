# AgentEscrowV3

Trustless payment escrow for agent-to-agent work. Built for the SYNTHESIS hackathon.

## What it does

- Buyer locks ERC20 tokens in escrow when creating a job
- Seller submits a `workHash` (hash of deliverable) to prove delivery
- Configurable dispute window (6h–7d): buyer can dispute or release; auto-release if silent
- **Partial arbitration**: arbiter splits funds by percentage (basis points), not binary winner-takes-all
- Optional milestone payments with correct accounting (no double-pay bug)
- Works with any ERC20 (USDC, USDT, etc.) on any EVM chain

## Quick Start (TypeScript SDK)

```typescript
import { AgentEscrow, JobStatus } from "@ai-agent-pay/sdk";
import { ethers } from "ethers";

const signer = new ethers.Wallet(PRIVATE_KEY, provider);
const escrow = new AgentEscrow(signer, AgentEscrow.POLYGON_ADDRESS);

// Buyer creates job (auto-approves token spend)
const jobId = await escrow.createJob({
  seller: "0xSellerAgentAddress",
  token:  "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359", // USDC on Polygon
  amount: 10_000_000n,  // 10 USDC
  deadline: Math.floor(Date.now() / 1000) + 7 * 86400,
  disputeWindowSeconds: 6 * 3600, // 6h for fast jobs
});

// Seller submits work
const workHash = AgentEscrow.hashDeliverable("ipfs://Qm...");
await escrow.submitWork(jobId, workHash);

// Buyer releases
await escrow.release(jobId);

// Or: auto-release after window closes
if (await escrow.canAutoRelease(jobId)) {
  await escrow.autoRelease(jobId);
}

// Arbiter resolves dispute with 70/30 split
await escrow.resolveDispute({ jobId, sellerBps: 7000 });
```

## Deployed Contracts (Polygon Mainnet)

| Contract | Address | TX |
|---|---|---|
| **AgentEscrowV3** ✨ latest | [`0xf8a7e6b5Decfe1b6F57e3D16d8005BCa5Be88B6A`](https://polygonscan.com/address/0xf8a7e6b5Decfe1b6F57e3D16d8005BCa5Be88B6A) | [`0xc5cd28...`](https://polygonscan.com/tx/0xc5cd2816b6260732d25748446a6c97497a102202f0bc05f50b12fff3fcfe8ec9) |
| AgentEscrowV2Fixed | [`0x9C8eefb386C395089D7906C67b48A3fd5ca14B9c`](https://polygonscan.com/address/0x9C8eefb386C395089D7906C67b48A3fd5ca14B9c) | [`0x700033...`](https://polygonscan.com/tx/0x7000334d05fe02ad378453724210bc33a9b2035f33aa012a4dde483b28d16b76) |
| **Network** | Polygon (chain 137) | |
| **Arbiter** | `0xe75895c6B674bcdBe910ed4d33fabCd6689290Fb` (placeholder) | |

## V3 Features

### Partial Arbitration

V2 forced a binary outcome. V3 lets the arbiter split by basis points:

```solidity
// 70% to seller, 30% refund to buyer
escrow.resolveDispute(jobId, 7000);

// 50/50 split
escrow.resolveDispute(jobId, 5000);

// Full refund
escrow.resolveDispute(jobId, 0);
```

### Dynamic Dispute Window

Set per-job at creation time (6h minimum, 7 days maximum):

```solidity
// Fast agent-to-agent micro-task
escrow.createJob(seller, token, amount, deadline, milestones, 6 hours);

// Large contract with unknown counterparty
escrow.createJob(seller, token, amount, deadline, milestones, 7 days);
```

### Milestone Accounting (no double-pay bug)

```solidity
// Tracks released amounts — _release() only sends the remainder
mapping(uint256 => uint256) public releasedAmount;
```

## Contracts

| File | Description |
|------|-------------|
| `src/AgentEscrowV3.sol` | ✨ Latest — partial arbitration + dynamic window |
| `src/AgentEscrowV2Fixed.sol` | All V2 bugs fixed, binary arbitration |
| `src/AgentEscrowV2.sol` | Original with critical bug (reference only) |
| `sdk/index.ts` | TypeScript SDK |

## Tests

```bash
# Install Foundry: https://book.getfoundry.sh/getting-started/installation
forge test -v
```

| Test file | Tests | Result |
|-----------|-------|--------|
| `test/AgentEscrowV3.t.sol` | 17 + 256 fuzz | ✅ all pass |
| `test/AgentEscrowV2Fixed.t.sol` | 15 | ✅ all pass |
| `test/AgentEscrowV2.t.sol` | 32 | ✅ 31 pass, 1 intentional fail (proves critical bug) |

## Security Audit

Full report: [`SECURITY_AUDIT.md`](./SECURITY_AUDIT.md)

| Severity | Issue | Status |
|----------|-------|--------|
| 🔴 Critical | Milestone double-payment drains victim jobs | Fixed in V2Fixed + V3 |
| 🟡 Medium | Disputed funds locked forever (no resolver) | Fixed — partial arbitration in V3 |
| 🟡 Medium | buyer == seller not rejected | Fixed |
| 🔵 Info | Raw IERC20 breaks USDT-style tokens | Fixed — SafeTransfer lib |
