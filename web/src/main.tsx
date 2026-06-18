import { createRoot } from "react-dom/client";
import { Ion } from "cesium";
import App from "./App";
import "./index.css";

// Optional ion token (better imagery/terrain). Token-free works without it.
const token = import.meta.env.VITE_CESIUM_ION_TOKEN;
if (token) Ion.defaultAccessToken = token;

const root = document.getElementById("root");
if (!root) throw new Error("missing #root element");
createRoot(root).render(<App />);
