import type { Toast } from "../hooks";

interface Props {
  toasts: Toast[];
  removeToast: (id: number) => void;
}

const colors = {
  success: "bg-green-900/80 border-green-700 text-green-200",
  error: "bg-red-900/80 border-red-700 text-red-200",
  info: "bg-blue-900/80 border-blue-700 text-blue-200",
};

export default function ToastContainer({ toasts, removeToast }: Props) {
  if (toasts.length === 0) return null;

  return (
    <div className="fixed bottom-4 right-4 z-50 flex flex-col gap-2 max-w-sm">
      {toasts.map((t) => (
        <div
          key={t.id}
          className={`px-4 py-3 rounded-lg border text-sm backdrop-blur-sm cursor-pointer ${colors[t.type]}`}
          onClick={() => removeToast(t.id)}
        >
          {t.message}
        </div>
      ))}
    </div>
  );
}
