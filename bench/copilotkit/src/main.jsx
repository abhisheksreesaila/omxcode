import { createRoot } from "react-dom/client";
import { CopilotKit } from "@copilotkit/react-core";
import { CopilotChat } from "@copilotkit/react-ui";
import "@copilotkit/react-ui/styles.css";
import "./app.css";
import { RenderUiTool } from "./RenderUiTool.jsx";

function App() {
  return (
    <CopilotKit runtimeUrl="/api/copilotkit" agent="bench" useSingleEndpoint>
      <RenderUiTool />
      <CopilotChat className="full-chat" labels={{ title: "Bench", initial: "Ask for a dashboard." }} />
    </CopilotKit>
  );
}

createRoot(document.getElementById("root")).render(<App />);
