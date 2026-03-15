import { useState } from "react";
import { Contract, parseUnits, type BrowserProvider } from "ethers";
import { CONTRACT_ADDRESS, ESCROW_ABI, ERC20_ABI, TOKENS } from "../contract";
import Spinner from "./Spinner";
import type { Toast } from "../hooks";

interface Props {
  provider: BrowserProvider | null;
  account: string | null;
  addToast: (msg: string, type: Toast["type"]) => void;
}

export default function CreateJob({ provider, account, addToast }: Props) {
  const [seller, setSeller] = useState("");
  const [tokenKey, setTokenKey] = useState("USDC");
  const [amount, setAmount] = useState("");
  const [deadline, setDeadline] = useState("");
  const [disputeHours, setDisputeHours] = useState(48);
  const [milestones, setMilestones] = useState<string[]>([]);
  const [loading, setLoading] = useState(false);
  const [txHash, setTxHash] = useState<string | null>(null);

  const addMilestone = () => setMilestones([...milestones, ""]);
  const removeMilestone = (i: number) => setMilestones(milestones.filter((_, idx) => idx !== i));
  const updateMilestone = (i: number, val: string) => {
    const m = [...milestones];
    m[i] = val;
    setMilestones(m);
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!provider || !account) {
      addToast("Connect wallet first", "error");
      return;
    }

    const token = TOKENS[tokenKey];
    if (!token) return;

    try {
      setLoading(true);
      setTxHash(null);

      const signer = await provider.getSigner();
      const escrow = new Contract(CONTRACT_ADDRESS, ESCROW_ABI, signer);
      const erc20 = new Contract(token.address, ERC20_ABI, signer);

      const parsedAmount = parseUnits(amount, token.decimals);
      const deadlineTs = Math.floor(new Date(deadline).getTime() / 1000);
      const disputeWindowSecs = disputeHours * 3600;

      let milestoneAmounts: bigint[] = [];
      if (milestones.length > 0) {
        milestoneAmounts = milestones.map((m) => parseUnits(m, token.decimals));
      }

      // Approve token spend
      addToast("Approving token spend...", "info");
      const allowance = await erc20.allowance(account, CONTRACT_ADDRESS);
      if (allowance < parsedAmount) {
        const approveTx = await erc20.approve(CONTRACT_ADDRESS, parsedAmount);
        await approveTx.wait();
        addToast("Token approved!", "success");
      }

      // Create job
      addToast("Creating job...", "info");
      const tx = await escrow.createJob(
        seller,
        token.address,
        parsedAmount,
        deadlineTs,
        milestoneAmounts,
        disputeWindowSecs
      );
      setTxHash(tx.hash);
      addToast("Transaction submitted, waiting for confirmation...", "info");

      const receipt = await tx.wait();
      const iface = escrow.interface;
      let jobId = "?";
      for (const log of receipt.logs) {
        try {
          const parsed = iface.parseLog({ topics: log.topics as string[], data: log.data });
          if (parsed?.name === "JobCreated") {
            jobId = parsed.args.jobId.toString();
          }
        } catch {}
      }

      addToast(`Job #${jobId} created successfully!`, "success");

      // Reset form
      setSeller("");
      setAmount("");
      setDeadline("");
      setMilestones([]);
      setDisputeHours(48);
    } catch (err: any) {
      const msg = err.reason || err.message || "Transaction failed";
      addToast(msg, "error");
    } finally {
      setLoading(false);
    }
  };

  const disputeLabel = disputeHours < 24
    ? `${disputeHours}h`
    : `${(disputeHours / 24).toFixed(1)}d`;

  return (
    <form onSubmit={handleSubmit} className="bg-[#111118] border border-[#1e1e2e] rounded-xl p-6 space-y-5">
      <h2 className="text-lg font-semibold text-white">Create New Job</h2>

      <div>
        <label className="block text-sm text-gray-400 mb-1">Seller Address</label>
        <input
          type="text"
          value={seller}
          onChange={(e) => setSeller(e.target.value)}
          placeholder="0x..."
          required
          className="w-full px-3 py-2.5 bg-[#0a0a0f] border border-[#1e1e2e] rounded-lg text-white text-sm font-mono focus:border-blue-500 focus:outline-none"
        />
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div>
          <label className="block text-sm text-gray-400 mb-1">Token</label>
          <select
            value={tokenKey}
            onChange={(e) => setTokenKey(e.target.value)}
            className="w-full px-3 py-2.5 bg-[#0a0a0f] border border-[#1e1e2e] rounded-lg text-white text-sm focus:border-blue-500 focus:outline-none"
          >
            {Object.keys(TOKENS).map((k) => (
              <option key={k} value={k}>{k}</option>
            ))}
          </select>
        </div>
        <div>
          <label className="block text-sm text-gray-400 mb-1">Amount</label>
          <input
            type="number"
            step="any"
            value={amount}
            onChange={(e) => setAmount(e.target.value)}
            placeholder={`e.g. 10 ${tokenKey}`}
            required
            className="w-full px-3 py-2.5 bg-[#0a0a0f] border border-[#1e1e2e] rounded-lg text-white text-sm focus:border-blue-500 focus:outline-none"
          />
        </div>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div>
          <label className="block text-sm text-gray-400 mb-1">Deadline</label>
          <input
            type="datetime-local"
            value={deadline}
            onChange={(e) => setDeadline(e.target.value)}
            required
            className="w-full px-3 py-2.5 bg-[#0a0a0f] border border-[#1e1e2e] rounded-lg text-white text-sm focus:border-blue-500 focus:outline-none [color-scheme:dark]"
          />
        </div>
        <div>
          <label className="block text-sm text-gray-400 mb-1">
            Dispute Window: {disputeLabel}
          </label>
          <input
            type="range"
            min={6}
            max={168}
            step={6}
            value={disputeHours}
            onChange={(e) => setDisputeHours(Number(e.target.value))}
            className="w-full mt-2 accent-blue-500"
          />
          <div className="flex justify-between text-xs text-gray-600 mt-1">
            <span>6h</span>
            <span>7d</span>
          </div>
        </div>
      </div>

      {/* Milestones */}
      <div>
        <div className="flex items-center justify-between mb-2">
          <label className="text-sm text-gray-400">Milestones (optional)</label>
          <button
            type="button"
            onClick={addMilestone}
            className="text-xs text-blue-400 hover:text-blue-300"
          >
            + Add Milestone
          </button>
        </div>
        {milestones.map((m, i) => (
          <div key={i} className="flex gap-2 mb-2">
            <input
              type="number"
              step="any"
              value={m}
              onChange={(e) => updateMilestone(i, e.target.value)}
              placeholder={`Milestone ${i + 1} amount`}
              className="flex-1 px-3 py-2 bg-[#0a0a0f] border border-[#1e1e2e] rounded-lg text-white text-sm focus:border-blue-500 focus:outline-none"
            />
            <button
              type="button"
              onClick={() => removeMilestone(i)}
              className="px-3 py-2 bg-red-900/30 border border-red-800/30 rounded-lg text-red-400 text-sm hover:bg-red-900/50"
            >
              X
            </button>
          </div>
        ))}
      </div>

      <button
        type="submit"
        disabled={loading || !account}
        className="w-full py-3 bg-blue-600 hover:bg-blue-700 disabled:bg-gray-700 disabled:text-gray-500 text-white rounded-lg font-medium transition-colors flex items-center justify-center gap-2"
      >
        {loading ? (
          <>
            <Spinner className="w-4 h-4" />
            Processing...
          </>
        ) : !account ? (
          "Connect Wallet to Create Job"
        ) : (
          "Create Job"
        )}
      </button>

      {txHash && (
        <div className="text-center">
          <a
            href={`https://polygonscan.com/tx/${txHash}`}
            target="_blank"
            rel="noopener noreferrer"
            className="text-sm text-blue-400 hover:text-blue-300 font-mono"
          >
            View on Polygonscan: {txHash.slice(0, 10)}...
          </a>
        </div>
      )}
    </form>
  );
}
