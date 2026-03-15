export const CONTRACT_ADDRESS = "0xf8a7e6b5Decfe1b6F57e3D16d8005BCa5Be88B6A";

export const TOKENS: Record<string, { address: string; decimals: number; symbol: string }> = {
  USDC:  { address: "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359", decimals: 6, symbol: "USDC" },
  USDCe: { address: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174", decimals: 6, symbol: "USDCe" },
  USDT:  { address: "0xc2132D05D31c914a87C6611C10748AEb04B58e8F", decimals: 6, symbol: "USDT" },
  WETH:  { address: "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619", decimals: 18, symbol: "WETH" },
};

export const ESCROW_ABI = [
  "function createJob(address seller, address token, uint256 amount, uint256 deadline, uint256[] milestoneAmounts, uint256 disputeWindowSeconds) returns (uint256 jobId)",
  "function submitWork(uint256 jobId, bytes32 workHash)",
  "function release(uint256 jobId)",
  "function dispute(uint256 jobId)",
  "function refund(uint256 jobId)",
  "function releaseMilestone(uint256 jobId)",
  "function rateJob(uint256 jobId, uint8 rating)",
  "function autoRelease(uint256 jobId)",
  "function arbiterTimeoutRelease(uint256 jobId)",
  "function resolveDispute(uint256 jobId, uint256 sellerBps)",
  "function getJob(uint256 jobId) view returns (tuple(address buyer, address seller, address token, uint256 amount, uint256 deadline, uint256 disputeWindow, bytes32 workHash, uint64 submittedAt, uint64 disputedAt, uint8 status))",
  "function getMilestones(uint256 jobId) view returns (uint256[])",
  "function remainingAmount(uint256 jobId) view returns (uint256)",
  "function jobCount() view returns (uint256)",
  "function sellerRating(address seller) view returns (uint256 avgX100, uint256 count)",
  "function sellerStats(address seller) view returns (uint256 completedJobs, uint256 disputedJobs, uint256 avgRatingX100, uint256 ratingCount)",
  "function protocolFeeBps() view returns (uint256)",
  "function feeCollector() view returns (address)",
  "function arbiterTimeoutSeconds() view returns (uint256)",
  "function jobRated(uint256 jobId) view returns (bool)",
  "function ARBITER() view returns (address)",
  "event JobCreated(uint256 indexed jobId, address buyer, address seller, address token, uint256 amount, uint256 deadline, uint256 disputeWindow)",
  "event WorkSubmitted(uint256 indexed jobId, bytes32 workHash)",
  "event Released(uint256 indexed jobId, address seller, uint256 sellerAmount, uint256 feeAmount)",
  "event SellerRated(uint256 indexed jobId, address indexed seller, uint8 rating)",
];

export const ERC20_ABI = [
  "function approve(address spender, uint256 amount) returns (bool)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
  "function decimals() view returns (uint8)",
];

export const STATUS_LABELS: Record<number, string> = {
  0: "Created",
  1: "Work Submitted",
  2: "Released",
  3: "Refunded",
  4: "Disputed",
  5: "Partially Resolved",
};

export const STATUS_COLORS: Record<number, string> = {
  0: "text-yellow-400",
  1: "text-blue-400",
  2: "text-green-400",
  3: "text-red-400",
  4: "text-orange-400",
  5: "text-purple-400",
};

export const POLYGON_CHAIN_ID = "0x89"; // 137
export const POLYGON_RPC = "https://polygon-rpc.com";
