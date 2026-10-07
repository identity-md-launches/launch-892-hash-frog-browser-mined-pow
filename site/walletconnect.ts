import { EthereumProvider } from "@walletconnect/ethereum-provider";
import QRCode from "qrcode";
export async function createWalletConnect(
  projectId: string,
  rpc: string,
  onUri: (uri: string, image: string) => void,
) {
  const provider = await EthereumProvider.init({
    projectId,
    chains: [1],
    showQrModal: false,
    rpcMap: { 1: rpc },
    optionalMethods: ["wallet_switchEthereumChain"],
    metadata: {
      name: "Hash Frog",
      description: "Browser-mined frogs on Ethereum",
      url: location.origin,
      icons: [new URL("./pond.svg", import.meta.url).href],
    },
  });
  provider.on("display_uri", async (uri: string) =>
    onUri(
      uri,
      await QRCode.toDataURL(uri, {
        width: 280,
        margin: 2,
        color: { dark: "#101b17", light: "#ffffff" },
      }),
    ),
  );
  return provider;
}
