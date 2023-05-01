import { parseEther, ParamType } from "ethers/lib/utils";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import getContractAddress from "../../deploy-helpers/getContractAddress";
import { ethers } from "hardhat";
import { version } from "../../package.json";
import { ICREATE3Factory, VeaOutboxArbToEthDevnet, VeaOutboxArbToEthDevnet__factory } from "../../typechain-types";
import { bytecode } from "../../artifacts/src/devnets/arbitrumToEth/VeaOutboxArbToEthDevnet.sol/VeaOutboxArbToEthDevnet.json";

enum ReceiverChains {
  ETHEREUM_GOERLI = 5,
  HARDHAT = 31337,
}

const paramsByChainId = {
  ETHEREUM_GOERLI: {
    deposit: parseEther("0.01"), // 0.1 eth, 120 eth budget for timeout
    // Average happy path wait time is 1 hour (30 min, 90 min), assume no censorship
    epochPeriod: 3600, // 60 min
    claimDelay: 0, // Assume sequencer online
    challengePeriod: 1800, // 1800, 30 min (assume no sequencer backdating)
    numEpochTimeout: 10000000000000, // never
    maxMissingBlocks: 10000000000000,
    arbitrumInbox: "0x6BEbC4925716945D46F0Ec336D5C2564F419682C",
  },
  HARDHAT: {
    deposit: parseEther("10"), // 120 eth budget for timeout
    // Average happy path wait time is 45 mins, assume no censorship
    epochPeriod: 1800, // 30 min
    claimDelay: 0, // 30 hours (24 hours sequencer backdating + 6 hour buffer)
    challengePeriod: 1800, // 30 min (assume no sequencer backdating)
    numEpochTimeout: 10000000000000, // 6 hours
    senderChainId: 31337,
    maxMissingBlocks: 10000000000000,
    arbitrumInbox: ethers.constants.AddressZero,
  },
};

const salt = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("Vea ArbGoerliToGoerli v" + version));

const getCreationCode = ({
  bytecode,
  constructorArgs,
}: {
  bytecode: string;
  constructorArgs: { types: string[] | ParamType[]; values: any[] };
}): string => {
  return `${bytecode}${ethers.utils.defaultAbiCoder.encode(constructorArgs.types, constructorArgs.values).slice(2)}`;
};

const deployOutbox: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { ethers, deployments, getNamedAccounts, getChainId, config } = hre;
  const { deploy } = deployments;
  const { providers } = ethers;

  // fallback to hardhat node signers on local network
  const deployer = (await getNamedAccounts()).deployer ?? (await hre.ethers.getSigners())[0].address;
  const chainId = Number(await getChainId());
  console.log("deploying to chainId %s with deployer %s", chainId, deployer);

  const senderNetworks = {
    ETHEREUM_MAINNET: config.networks.arbitrum,
    ETHEREUM_GOERLI: config.networks.arbitrumGoerli,
    HARDHAT: config.networks.localhost,
  };

  const { deposit, epochPeriod, challengePeriod, numEpochTimeout, claimDelay, maxMissingBlocks, arbitrumInbox } =
    paramsByChainId[ReceiverChains[chainId]];

  // Hack to predict the deployment address on the sender chain.
  // TODO: use deterministic deployments

  // ----------------------------------------------------------------------------------------------
  const hardhatDeployer = async () => {
    let nonce = await ethers.provider.getTransactionCount(deployer);
    nonce += 4; // SenderGatewayToEthereum deploy tx will be the 5th after this, same network for both sender/receiver.

    const senderGatewayAddress = getContractAddress(deployer, nonce);
    console.log("calculated future SenderGatewayToEthereum address for nonce %d: %s", nonce, senderGatewayAddress);
    nonce -= 2;

    const arbSysAddress = getContractAddress(deployer, nonce);
    console.log("calculated future arbSysAddress address for nonce %d: %s", nonce, arbSysAddress);
    nonce += 1;

    const veaInboxAddress = getContractAddress(deployer, nonce);
    console.log("calculated future VeaInbox for nonce %d: %s", nonce, veaInboxAddress);
    nonce += 4;

    const inboxAddress = getContractAddress(deployer, nonce);
    console.log("calculated future inboxAddress for nonce %d: %s", nonce, inboxAddress);

    const veaOutbox = await deploy("VeaOutbox", {
      from: deployer,
      contract: "VeaOutboxMockArbToEth",
      args: [
        arbSysAddress,
        deposit,
        epochPeriod,
        challengePeriod,
        numEpochTimeout,
        claimDelay,
        veaInboxAddress,
        inboxAddress,
        maxMissingBlocks,
      ],
      log: true,
    });

    await deploy("ReceiverGateway", {
      from: deployer,
      contract: "ReceiverGatewayMock",
      args: [veaOutbox.address, senderGatewayAddress],
      gasLimit: 4000000,
      log: true,
    });
  };

  // ----------------------------------------------------------------------------------------------
  const liveDeployer = async () => {
    const create3Deployment = await hre.companionNetworks.arbitrumGoerli.deployments.get("CREATE3Factory");
    const create3 = (await ethers.getContract("CREATE3Factory")) as ICREATE3Factory;
    const veaInboxAddress = await create3.getDeployed(create3Deployment.address, salt);
    console.log("CREATE3: deploying to %s from factory %s", veaInboxAddress, create3Deployment.address);

    const bytecode = VeaOutboxArbToEthDevnet__factory.bytecode;
    const constructorArgs = {
      types: ["uint256", "uint256", "uint256", "uint256", "uint256", "address", "address", "uint256"],
      values: [
        deposit,
        epochPeriod,
        challengePeriod,
        numEpochTimeout,
        claimDelay,
        veaInboxAddress,
        arbitrumInbox,
        maxMissingBlocks,
      ],
    };
    const code = getCreationCode({ bytecode, constructorArgs });
    const tx = await create3.deploy(salt, code);
    console.log(await tx.wait());
  };

  // ----------------------------------------------------------------------------------------------
  if (chainId === 31337) {
    await hardhatDeployer();
  } else {
    await liveDeployer();
  }
};

deployOutbox.tags = ["ArbGoerliToGoerliOutbox"];
deployOutbox.skip = async ({ getChainId }) => {
  const chainId = Number(await getChainId());
  console.log(chainId);
  return !(chainId === 5 || chainId === 31337);
};

export default deployOutbox;
