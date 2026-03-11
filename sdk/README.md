# @ai-agent-pay/sdk

TypeScript SDK for AgentEscrowV3 — trustless payment escrow for agent-to-agent work.

## Install

```bash
npm install @ai-agent-pay/sdk ethers
```

## Quick Start

```typescript
import { AgentEscrow, JobStatus } from "@ai-agent-pay/sdk";
import { ethers } from "ethers";

const provider = new ethers.JsonRpcProvider("https://polygon-rpc.com");
const signer = new ethers.Wallet(PRIVATE_KEY, provider);

// Connect to deployed contract on Polygon mainnet
const escrow = new AgentEscrow(signer, AgentEscrow.POLYGON_ADDRESS);

// ── Buyer: create job ──────────────────────────────────────────────────────

const jobId = await escrow.createJob({
  seller: "0xSellerAgentAddress",
  token:  "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359", // USDC on Polygon
  amount: 10_000_000n, // 10 USDC (6 decimals)
  deadline: Math.floor(Date.now() / 1000) + 7 * 24 * 3600, // 7 days
  disputeWindowSeconds: 6 * 3600, // 6h window for fast jobs
  // optional: split into milestones
  // milestones: [3_000_000n, 7_000_000n], // 3 + 7 USDC
});

console.log("Job created:", jobId);

// ── Seller: submit work ────────────────────────────────────────────────────

// Hash your deliverable (IPFS CID, file hash, etc.)
const workHash = AgentEscrow.hashDeliverable("ipfs://Qm...your-result");
await escrow.submitWork(jobId, workHash);

// ── Buyer: release or dispute ──────────────────────────────────────────────

const job = await escrow.getJob(jobId);
if (job.status === JobStatus.WorkSubmitted) {
  // Happy path
  await escrow.release(jobId);

  // Or dispute within the window
  // await escrow.dispute(jobId);
}

// ── Auto-release (anyone can call after window closes) ─────────────────────

if (await escrow.canAutoRelease(jobId)) {
  await escrow.autoRelease(jobId);
}

// ── Arbiter: partial resolution ────────────────────────────────────────────

// 70% to seller, 30% back to buyer
await escrow.resolveDispute({ jobId, sellerBps: 7000 });
// Full refund: sellerBps = 0
// Full payout: sellerBps = 10000

// ── Milestone release ──────────────────────────────────────────────────────

await escrow.releaseMilestone(jobId); // releases next slice
const remaining = await escrow.remainingAmount(jobId);
```

## Contract

| | |
|---|---|
| **AgentEscrowV3 (Polygon mainnet)** | `0x9C8eefb386C395089D7906C67b48A3fd5ca14B9c` |
| **Source** | [github.com/xjin1020/ai_agent_pay](https://github.com/xjin1020/ai_agent_pay) |

## Dispute Window

Set `disputeWindowSeconds` at job creation (default: 48h):
- Min: 6h — fast jobs between known agents
- Max: 7 days — large contracts with unknowns
- Default: 48h — balanced

## Partial Arbitration

`resolveDispute({ jobId, sellerBps })` splits remaining funds:

| sellerBps | Outcome |
|-----------|---------|
| `10000` | 100% to seller |
| `7000` | 70% seller / 30% buyer |
| `5000` | 50/50 split |
| `0` | Full refund to buyer |
