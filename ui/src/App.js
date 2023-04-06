import "./App.css";
import { useState } from "react";
import MetaMask from "./components/MetaMask.js";
import { MetaMaskProvider } from "./contexts/MetaMask";

const App = () => {
  const [pairs, setPairs] = useState([]);

  return (
    <MetaMaskProvider>
      <div className="App flex flex-col justify-between items-center w-full h-full">
        <MetaMask />

        <footer></footer>
      </div>
    </MetaMaskProvider>
  );
};

export default App;
