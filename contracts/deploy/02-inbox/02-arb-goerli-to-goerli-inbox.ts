import { HardhatRuntimeEnvironment } from "hardhat/types";
import { DeployFunction } from "hardhat-deploy/types";
import { ParamType } from "ethers/lib/utils";
import { ethers } from "hardhat";
import { version } from "../../package.json";
import { ICREATE3Factory, VeaOutboxArbToEthDevnet, VeaInboxArbToEth__factory } from "../../typechain-types";

enum SenderChains {
  ARBITRUM_GOERLI = 421613,
  HARDHAT = 31337,
}

const paramsByChainId = {
  ARBITRUM_GOERLI: {
    epochPeriod: 3600, // 1 hour
  },
  HARDHAT: {
    epochPeriod: 1800, // 30 minutes
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
  console.log("%s", ethers.utils.defaultAbiCoder.encode(constructorArgs.types, constructorArgs.values));
  return `${bytecode}${ethers.utils.defaultAbiCoder.encode(constructorArgs.types, constructorArgs.values).slice(2)}`;
};

// TODO: use deterministic deployments
const deployInbox: DeployFunction = async (hre: HardhatRuntimeEnvironment) => {
  const { deployments, getNamedAccounts, getChainId } = hre;
  const { deploy, execute } = deployments;
  const chainId = Number(await getChainId());

  // fallback to hardhat node signers on local network
  const deployer = (await getNamedAccounts()).deployer ?? (await hre.ethers.getSigners())[0].address;
  console.log("deployer: %s", deployer);

  const { epochPeriod } = paramsByChainId[SenderChains[chainId]];

  // ----------------------------------------------------------------------------------------------
  const hardhatDeployer = async () => {
    const veaOutbox = await deployments.get("VeaOutbox");

    const arbSysMock = await deploy("ArbSysMock", { from: deployer, log: true });

    const veaInbox = await deploy("VeaInbox", {
      from: deployer,
      contract: "VeaInboxMockArbToEth",
      args: [arbSysMock.address, epochPeriod, veaOutbox.address],
    });

    const receiverGateway = await deployments.get("ReceiverGateway");
    const receiverChainId = 31337;

    const senderGateway = await deploy("SenderGateway", {
      from: deployer,
      contract: "SenderGatewayMock",
      args: [veaInbox.address, receiverGateway.address],
      gasLimit: 4000000,
      log: true,
    });

    const outbox = await deploy("OutboxMock", {
      from: deployer,
      args: [veaInbox.address],
      log: true,
    });

    const bridge = await deploy("BridgeMock", {
      from: deployer,
      args: [outbox.address],
      log: true,
    });

    await deploy("InboxMock", {
      from: deployer,
      args: [bridge.address],
      log: true,
    });
  };

  // ----------------------------------------------------------------------------------------------
  const liveDeployer = async () => {
    const veaOutbox = await hre.companionNetworks.goerli.deployments.get("VeaOutboxArbToEthDevnet");

    const create3 = (await ethers.getContract("CREATE3Factory")) as ICREATE3Factory;
    const veaInboxAddress = await create3.getDeployed(create3.address, salt);
    console.log("CREATE3: deploying to %s from factory %s", veaInboxAddress, create3.address);

    const bytecode = VeaInboxArbToEth__factory.bytecode;
    const constructorArgs = {
      types: ["uint256", "address"],
      values: [epochPeriod, veaOutbox.address],
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

deployInbox.tags = ["ArbGoerliToGoerliInbox"];
deployInbox.skip = async ({ getChainId }) => {
  const chainId = Number(await getChainId());
  console.log(chainId);
  return !(chainId === 421613 || chainId === 31337);
};
deployInbox.runAtTheEnd = true;

export default deployInbox;
