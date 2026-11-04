import { useFrontendTool } from "@copilotkit/react-core";
import { Node } from "./components.jsx";

// The agent calls render_ui({ui: node}); CopilotKit hands render() the partial args while they stream.
export function RenderUiTool() {
  useFrontendTool({
    name: "render_ui",
    description: "Draw a UI tree in the chat.",
    parameters: [{ name: "ui", type: "object", description: "The root node: {component, ...props, children}", required: true }],
    handler: async () => ({ shown: true }),
    render: ({ args, status }) => (
      <div className="genui" data-status={status}>
        <Node node={args?.ui} />
      </div>
    ),
  });
  return null;
}
