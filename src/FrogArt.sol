// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @notice Original geometric pond frogs. All visual variation comes from the mined seed.
/// The 256-bit genome is drawn in 64 colored tiles, making each seed's image one of one.
library FrogArt {
    using Strings for uint256;

    function traits(bytes32 seed) internal pure returns (string memory skin, string memory eyes, string memory crown) {
        uint256 h = uint256(keccak256(abi.encode(seed, "HASHFROG_ART_V1")));
        skin = h % 128 == 0 ? "Moonstone" : h % 32 == 0 ? "Sunmetal" : h % 4 == 0 ? "Orchid" : "Moss";
        eyes = (h >> 8) % 16 == 0 ? "Stargazer" : (h >> 8) % 3 == 0 ? "Sleepy" : "Wide awake";
        crown = (h >> 16) % 64 == 0 ? "Orbit" : (h >> 16) % 8 == 0 ? "Reed crown" : "Dew";
    }

    function svg(bytes32 seed) internal pure returns (string memory) {
        uint256 h = uint256(keccak256(abi.encode(seed, "HASHFROG_ART_V1")));
        string memory color = h % 128 == 0 ? "#e3eeff" : h % 32 == 0 ? "#f5c451" : h % 4 == 0 ? "#cf9feb" : "#b1df64";
        string memory tiles;
        string[16] memory palette = [
            "#193d38",
            "#23554b",
            "#357358",
            "#5a9563",
            "#83b56d",
            "#b1df64",
            "#dfef9c",
            "#f6ecd1",
            "#102a33",
            "#325a72",
            "#7195a8",
            "#adc9c7",
            "#744f71",
            "#ab7e97",
            "#dfb3a9",
            "#f5c451"
        ];
        for (uint256 i; i < 64; ++i) {
            tiles = string.concat(
                tiles,
                '<rect x="',
                (20 + (i % 16) * 18).toString(),
                '" y="',
                (270 + (i / 16) * 10).toString(),
                '" width="16" height="8" fill="',
                palette[(uint256(seed) >> (i * 4)) & 15],
                '"/>'
            );
        }
        string memory accessory = (h >> 16) % 64 == 0
            ? '<ellipse cx="160" cy="59" rx="62" ry="15" fill="none" stroke="#f5c451" stroke-width="5"/>'
            : (h >> 16) % 8 == 0
                ? '<path d="M130 86L124 49L149 70L163 38L179 71L201 49L193 86Z" fill="#f5c451"/>'
                : '<path d="M162 61Q180 83 162 87Q144 83 162 61" fill="#adc9c7"/>';
        string memory pupils = (h >> 8) % 16 == 0
            ? '<path d="M107 108L111 119L123 122L111 126L107 138L102 126L91 122L102 118Z M214 108L218 119L230 122L218 126L214 138L209 126L198 122L209 118Z" fill="#163e35"/>'
            : (h >> 8) % 3 == 0
                ? '<path d="M93 125H121M199 125H227" stroke="#163e35" stroke-width="7"/>'
                : '<rect x="104" y="112" width="10" height="23" rx="5" fill="#163e35"/><rect x="208" y="112" width="10" height="23" rx="5" fill="#163e35"/>';
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 320"><rect width="320" height="320" rx="24" fill="#102a28"/><circle cx="250" cy="51" r="21" fill="#315549"/><path d="M20 217Q160 172 300 217Q160 261 20 217" fill="#357358"/><path d="M162 217L298 217" stroke="#102a28" stroke-width="3"/><g fill="',
            color,
            '" stroke="#163e35" stroke-width="5"><ellipse cx="111" cy="220" rx="48" ry="17"/><ellipse cx="211" cy="220" rx="48" ry="17"/><path d="M91 164Q61 198 104 215H217Q258 198 229 164Q229 123 161 121Q91 123 91 164Z"/><circle cx="107" cy="122" r="33"/><circle cx="214" cy="122" r="33"/></g><ellipse cx="161" cy="189" rx="42" ry="24" fill="#e2e9ab"/><circle cx="107" cy="122" r="21" fill="#f6ecd1"/><circle cx="214" cy="122" r="21" fill="#f6ecd1"/>',
            pupils,
            '<path d="M127 155Q161 181 195 155" fill="none" stroke="#163e35" stroke-width="5" stroke-linecap="round"/><circle cx="117" cy="155" r="7" fill="#dfb3a9"/><circle cx="205" cy="155" r="7" fill="#dfb3a9"/>',
            accessory,
            tiles,
            "</svg>"
        );
    }

    function uri(uint256 id, bytes32 seed) internal pure returns (string memory) {
        (string memory skin, string memory eyes, string memory crown) = traits(seed);
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"Hash Frog #',
                        id.toString(),
                        '","description":"An original on-chain pond frog, mined by proof of work. Its 256-bit genome mosaic is one of one. Burning redeems its share of the pond vault.","image":"data:image/svg+xml;base64,',
                        Base64.encode(bytes(svg(seed))),
                        '","attributes":[{"trait_type":"Skin","value":"',
                        skin,
                        '"},{"trait_type":"Eyes","value":"',
                        eyes,
                        '"},{"trait_type":"Adornment","value":"',
                        crown,
                        '"},{"trait_type":"Genome","value":"',
                        Strings.toHexString(uint256(seed), 32),
                        '"}]}'
                    )
                )
            )
        );
    }
}
