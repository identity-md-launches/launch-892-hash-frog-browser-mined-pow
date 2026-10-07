// The pinned ethers ESM runtime is retained from the original site. Its dynamically
// loaded Solidity ABI boundary is checked on chain; app state is typed separately.
export const BrowserProvider:any, JsonRpcProvider:any, FallbackProvider:any, Contract:any, Interface:any,
 parseEther:(value:string)=>bigint,formatEther:(value:bigint)=>string,isAddress:(value:string)=>boolean,
 toBeHex:(value:bigint|number,width?:number)=>string,keccak256:any,toUtf8Bytes:any;
