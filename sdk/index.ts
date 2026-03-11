/**
 * AgentEscrowV3 SDK
 * Trustless payment escrow for agent-to-agent work.
 * Deployed on Polygon: 0x9C8eefb386C395089D7906C67b48A3fd5ca14B9c (V2Fixed)
 *
 * Usage:
 *   const sdk = new AgentEscrow(signer, contractAddress);
 *   const jobId = await sdk.createJob({ seller, token, amount, deadline });
 *   await sdk.submitWork(jobId, sha256OfDeliverable);
 *   await sdk.release(jobId);
 */

import { Contract, Signer, Provider, BigNumberish, ethers } from "ethers";

// ─── ABI (minimal — only what the SDK needs) ─────────────────────────────────
const ABI = [
  // create
  "function createJob(address seller, address token, uint256 amount, uint256 deadline, uint256[] milestoneAmounts, uint256 disputeWindowSeconds) returns (uint256 jobId)",
  // seller
  "function submitWork(uint256 jobId, bytes32 workHash)",
  // buyer
  "function release(uint256 jobId)",
  "function dispute(uint256 jobId)",
  "function refund(uint256 jobId)",
  "function releaseMilestone(uint256 jobId)",
  // anyone
  "function autoRelease(uint256 jobId)",
  // arbiter
  "function resolveDispute(uint256 jobId, uint256 sellerBps)",
  // view
  "function getJob(uint256 jobId) view returns (tuple(address buyer, address seller, address token, uint256 amount, uint256 deadline, uint256 disputeWindow, bytes32 workHash, uint64 submittedAt, uint8 status))",
  "function getMilestones(uint256 jobId) view returns (uint256[])",
  "function remainingAmount(uint256 jobId) view returns (uint256)",
  "function jobCount() view returns (uint256)",
  // events
  "event JobCreated(uint256 indexed jobId, address buyer, address seller, address token, uint256 amount, uint256 deadline, uint256 disputeWindow)",
  "event WorkSubmitted(uint256 indexed jobId, bytes32 workHash)",
  "event Released(uint256 indexed jobId, address seller, uint256 amount)",
  "event Disputed(uint256 indexed jobId)",
  "event DisputeResolved(uint256 indexed jobId, address seller, uint256 sellerAmount, address buyer, uint256 buyerAmount)",
  "event Refunded(uint256 indexed jobId, address buyer, uint256 amount)",
];

const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function decimals() view returns (uint8)",
];

// ─── Types ────────────────────────────────────────────────────────────────────

export enum JobStatus {
  Created = 0,
  WorkSubmitted = 1,
  Released = 2,
  Refunded = 3,
  Disputed = 4,
  PartiallyResolved = 5,
}

export interface Job {
  buyer: string;
  seller: string;
  token: string;
  amount: bigint;
  deadline: bigint;
  disputeWindow: bigint;
  workHash: string;
  submittedAt: bigint;
  status: JobStatus;
}

export interface CreateJobParams {
  /** Address of the seller (agent doing the work) */
  seller: string;
  /** ERC20 token address (USDC, USDT, etc.) */
  token: string;
  /** Payment amount in token base units */
  amount: BigNumberish;
  /** Unix timestamp of the job deadline */
  deadline: BigNumberish;
  /** Optional milestone amounts that must sum to amount */
  milestones?: BigNumberish[];
  /**
   * Dispute window in seconds. Defaults to 48h.
   * Must be between 6h and 7 days.
   */
  disputeWindowSeconds?: BigNumberish;
  /** If true, auto-approves token spend before creating job */
  autoApprove?: boolean;
}

export interface ResolveDisputeParams {
  jobId: BigNumberish;
  /** Basis points for seller (0–10000). 5000 = 50/50 split. */
  sellerBps: BigNumberish;
}

// ─── SDK ─────────────────────────────────────────────────────────────────────

export class AgentEscrow {
  private contract: Contract;
  private signer: Signer;

  /** Polygon mainnet deployment (V2Fixed) */
  static readonly POLYGON_ADDRESS = "0x9C8eefb386C395089D7906C67b48A3fd5ca14B9c";

  constructor(signer: Signer, contractAddress: string) {
    this.signer = signer;
    this.contract = new Contract(contractAddress, ABI, signer);
  }

  // ── Create ─────────────────────────────────────────────────────────────────

  /**
   * Create a new escrow job.
   * Locks `amount` tokens from the buyer into the contract.
   * @returns jobId
   */
  async createJob(params: CreateJobParams): Promise<bigint> {
    const {
      seller,
      token,
      amount,
      deadline,
      milestones = [],
      disputeWindowSeconds = 0,
      autoApprove = true,
    } = params;

    if (autoApprove) {
      await this._ensureApproval(token, amount);
    }

    const tx = await this.contract.createJob(
      seller,
      token,
      amount,
      deadline,
      milestones,
      disputeWindowSeconds
    );
    const receipt = await tx.wait();

    // Parse JobCreated event to get jobId
    const iface = this.contract.interface;
    for (const log of receipt.logs) {
      try {
        const parsed = iface.parseLog(log);
        if (parsed?.name === "JobCreated") {
          return parsed.args.jobId as bigint;
        }
      } catch {}
    }
    throw new Error("JobCreated event not found in receipt");
  }

  // ── Seller ─────────────────────────────────────────────────────────────────

  /**
   * Seller submits work hash to open the dispute window.
   * @param workHash SHA256 hash of the deliverable (bytes32)
   */
  async submitWork(jobId: BigNumberish, workHash: string): Promise<void> {
    const tx = await this.contract.submitWork(jobId, workHash);
    await tx.wait();
  }

  /**
   * Helper: hash a string deliverable to bytes32.
   * Use this to generate the workHash from your actual output.
   */
  static hashDeliverable(content: string): string {
    return ethers.keccak256(ethers.toUtf8Bytes(content));
  }

  // ── Buyer ──────────────────────────────────────────────────────────────────

  /** Buyer confirms work is good and releases payment to seller. */
  async release(jobId: BigNumberish): Promise<void> {
    const tx = await this.contract.release(jobId);
    await tx.wait();
  }

  /**
   * Buyer disputes within the dispute window.
   * Locks funds until arbiter resolves.
   */
  async dispute(jobId: BigNumberish): Promise<void> {
    const tx = await this.contract.dispute(jobId);
    await tx.wait();
  }

  /** Buyer reclaims funds if seller never submitted work before deadline. */
  async refund(jobId: BigNumberish): Promise<void> {
    const tx = await this.contract.refund(jobId);
    await tx.wait();
  }

  /** Buyer releases next milestone slice. */
  async releaseMilestone(jobId: BigNumberish): Promise<void> {
    const tx = await this.contract.releaseMilestone(jobId);
    await tx.wait();
  }

  // ── Anyone ─────────────────────────────────────────────────────────────────

  /** Auto-releases payment after dispute window closes without dispute. */
  async autoRelease(jobId: BigNumberish): Promise<void> {
    const tx = await this.contract.autoRelease(jobId);
    await tx.wait();
  }

  // ── Arbiter ────────────────────────────────────────────────────────────────

  /**
   * Arbiter resolves a disputed job with partial split.
   * @param sellerBps Basis points for seller (0–10000).
   *   - 10000 = 100% to seller
   *   - 5000  = 50/50 split
   *   - 0     = full refund to buyer
   */
  async resolveDispute(params: ResolveDisputeParams): Promise<void> {
    const tx = await this.contract.resolveDispute(params.jobId, params.sellerBps);
    await tx.wait();
  }

  // ── View ───────────────────────────────────────────────────────────────────

  async getJob(jobId: BigNumberish): Promise<Job> {
    const j = await this.contract.getJob(jobId);
    return {
      buyer:         j.buyer,
      seller:        j.seller,
      token:         j.token,
      amount:        j.amount,
      deadline:      j.deadline,
      disputeWindow: j.disputeWindow,
      workHash:      j.workHash,
      submittedAt:   j.submittedAt,
      status:        Number(j.status) as JobStatus,
    };
  }

  async getMilestones(jobId: BigNumberish): Promise<bigint[]> {
    return await this.contract.getMilestones(jobId);
  }

  async remainingAmount(jobId: BigNumberish): Promise<bigint> {
    return await this.contract.remainingAmount(jobId);
  }

  async jobCount(): Promise<bigint> {
    return await this.contract.jobCount();
  }

  /** Check if the dispute window is still open for a job. */
  async isDisputeWindowOpen(jobId: BigNumberish): Promise<boolean> {
    const job = await this.getJob(jobId);
    const now = BigInt(Math.floor(Date.now() / 1000));
    return now <= job.submittedAt + job.disputeWindow;
  }

  /** Check if auto-release is available for a job. */
  async canAutoRelease(jobId: BigNumberish): Promise<boolean> {
    const job = await this.getJob(jobId);
    if (job.status !== JobStatus.WorkSubmitted) return false;
    const now = BigInt(Math.floor(Date.now() / 1000));
    return now > job.submittedAt + job.disputeWindow;
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  private async _ensureApproval(
    tokenAddress: string,
    amount: BigNumberish
  ): Promise<void> {
    const token = new Contract(tokenAddress, ERC20_ABI, this.signer);
    const signerAddr = await this.signer.getAddress();
    const contractAddr = await this.contract.getAddress();
    const allowance: bigint = await token.allowance(signerAddr, contractAddr);
    if (allowance < BigInt(amount.toString())) {
      const tx = await token.approve(contractAddr, ethers.MaxUint256);
      await tx.wait();
    }
  }
}

// ─── Convenience re-exports ───────────────────────────────────────────────────
export { ethers };
