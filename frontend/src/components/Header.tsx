interface Props {
  account: string | null;
  balance: string;
  chainId: string;
  onConnect: () => void;
}

export default function Header({ account, balance, chainId, onConnect }: Props) {
  const shortAddr = account ? `${account.slice(0, 6)}...${account.slice(-4)}` : "";
  const isPolygon = chainId === "0x89";

  return (
    <header className="border-b border-[#1e1e2e] bg-[#0d0d14]/80 backdrop-blur-sm sticky top-0 z-50">
      <div className="max-w-5xl mx-auto px-4 py-4 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="w-8 h-8 rounded-lg bg-blue-600 flex items-center justify-center text-white font-bold text-sm">
            AE
          </div>
          <div>
            <h1 className="text-lg font-bold text-white leading-tight">AgentEscrow</h1>
            <p className="text-xs text-gray-500">v4 — Agents that Pay</p>
          </div>
        </div>

        {account ? (
          <div className="flex items-center gap-3">
            <div className="hidden sm:flex items-center gap-2 px-3 py-1.5 bg-[#111118] rounded-lg text-xs">
              <span className={`w-2 h-2 rounded-full ${isPolygon ? "bg-green-400" : "bg-red-400"}`} />
              <span className="text-gray-400">{isPolygon ? "Polygon" : "Wrong Network"}</span>
            </div>
            <div className="px-3 py-1.5 bg-[#111118] rounded-lg text-xs text-gray-300">
              {parseFloat(balance).toFixed(4)} POL
            </div>
            <div className="px-3 py-1.5 bg-blue-600/20 border border-blue-600/30 rounded-lg text-xs text-blue-400 font-mono">
              {shortAddr}
            </div>
          </div>
        ) : (
          <button
            onClick={onConnect}
            className="px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg text-sm font-medium transition-colors"
          >
            Connect Wallet
          </button>
        )}
      </div>
    </header>
  );
}
