import { useState, useEffect } from "react";
import { Contract, JsonRpcProvider, type BrowserProvider } from "ethers";
import { CONTRACT_ADDRESS, ESCROW_ABI, POLYGON_RPC } from "../contract";
import Spinner from "./Spinner";

interface Props {
  provider: BrowserProvider | null;
}

export default function Dashboard({ provider }: Props) {
  const [jobCount, setJobCount] = useState<string>("-");
  const [feeBps, setFeeBps] = useState<string>("-");
  const [arbiter, setArbiter] = useState<string>("-");
  const [timeout, setTimeout_] = useState<string>("-");
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const load = async () => {
      try {
        const p = provider || new JsonRpcProvider(POLYGON_RPC);
        const contract = new Contract(CONTRACT_ADDRESS, ESCROW_ABI, p);
        const [jc, fee, arb, to] = await Promise.all([
          contract.jobCount(),
          contract.protocolFeeBps(),
          contract.ARBITER(),
          contract.arbiterTimeoutSeconds(),
        ]);
        setJobCount(jc.toString());
        setFeeBps(`${(Number(fee) / 100).toFixed(2)}%`);
        setArbiter(arb);
        setTimeout_(`${Number(to) / 86400} days`);
      } catch (e) {
        console.error("Dashboard load error:", e);
      } finally {
        setLoading(false);
      }
    };
    load();
  }, [provider]);

  if (loading) {
    return (
      <div className="flex justify-center py-20">
        <Spinner className="w-8 h-8 text-blue-500" />
      </div>
    );
  }

  const stats = [
    { label: "Total Jobs", value: jobCount, icon: "📋" },
    { label: "Protocol Fee", value: feeBps, icon: "💰" },
    { label: "Arbiter Timeout", value: timeout, icon: "⏱️" },
  ];

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        {stats.map((s) => (
          <div key={s.label} className="bg-[#111118] border border-[#1e1e2e] rounded-xl p-5">
            <div className="text-2xl mb-2">{s.icon}</div>
            <div className="text-2xl font-bold text-white">{s.value}</div>
            <div className="text-sm text-gray-500 mt-1">{s.label}</div>
          </div>
        ))}
      </div>

      <div className="bg-[#111118] border border-[#1e1e2e] rounded-xl p-5 space-y-3">
        <h3 className="text-sm font-medium text-gray-400 uppercase tracking-wider">Contract Info</h3>
        <div className="flex flex-col sm:flex-row sm:items-center gap-2">
          <span className="text-sm text-gray-500">Address:</span>
          <a
            href={`https://polygonscan.com/address/${CONTRACT_ADDRESS}`}
            target="_blank"
            rel="noopener noreferrer"
            className="font-mono text-sm text-blue-400 hover:text-blue-300 break-all"
          >
            {CONTRACT_ADDRESS}
          </a>
        </div>
        <div className="flex flex-col sm:flex-row sm:items-center gap-2">
          <span className="text-sm text-gray-500">Arbiter:</span>
          <a
            href={`https://polygonscan.com/address/${arbiter}`}
            target="_blank"
            rel="noopener noreferrer"
            className="font-mono text-sm text-blue-400 hover:text-blue-300 break-all"
          >
            {arbiter}
          </a>
        </div>
        <div className="flex items-center gap-2">
          <span className="text-sm text-gray-500">Network:</span>
          <span className="text-sm text-white flex items-center gap-1.5">
            <span className="w-2 h-2 rounded-full bg-purple-400" />
            Polygon (Chain ID: 137)
          </span>
        </div>
      </div>

      <div className="bg-gradient-to-r from-blue-900/20 to-purple-900/20 border border-blue-800/30 rounded-xl p-6">
        <h3 className="text-lg font-semibold text-white mb-2">SYNTHESIS Hackathon — Agents that Pay</h3>
        <p className="text-sm text-gray-400">
          Trustless payment escrow with on-chain reputation for agent-to-agent work.
          Scoped spending, verifiable delivery, partial arbitration, and anti-censorship guarantees.
        </p>
      </div>
    </div>
  );
}
