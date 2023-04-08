const config = {
  token0Address: "0x59b670e9fA9D0A427751Af201D676719a970857b",
  token1Address: "0x4ed7c70F96B99c776995fB64377f0d4aB3B0e1C1",
  poolAddress: "0x322813Fd9A801c5507c9de605d63CEA4f2CE6c44",
  managerAddress: "0xa85233C63b9Ee964Add6F2cffe00Fd84eb32338f",
  quoterAddress: "0x4A679253410272dd5232B3Ff7cF5dbB88f295319",
  ABIs: {
    ERC20: require("./abi/ERC20.json"),
    Pool: require("./abi/Pool.json"),
    Manager: require("./abi/Manager.json"),
    Quoter: require("./abi/Quoter.json"),
  },
};

export default config;
