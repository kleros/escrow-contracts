pragma solidity ^0.8.0;

import { ERC20PresetMinterPauser } from "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";

// mock class using ERC20
contract ERC20Mock is ERC20PresetMinterPauser {
    constructor(address initialAccount, uint256 initialBalance, string memory name, string memory symbol) ERC20PresetMinterPauser(name, symbol) {
        mint(initialAccount, initialBalance);
    }
}