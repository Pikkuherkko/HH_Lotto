// SPDX-License-Identifier: MIT

pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/interfaces/VRFCoordinatorV2Interface.sol";
import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";

error Raffle__NotEnoughETHEntered();
error Raffle__TransferFailed();
error Raffle__NotOpen();
error Raffle__UpkeepNotNeeded(uint256 currentBalance, uint256 numPlayers, uint256 raffleState);

/** @title lotto-älysopimus
 * @author Pikkuherkko
 * @notice tämä älysopimus on peukaloimaton hajautettuälysopimus
 * @dev tässä käytetään Chainlink VRF V2:sta ja Chainlink Keepersiä
 */
contract Raffle is VRFConsumerBaseV2, KeeperCompatibleInterface {
    /* Type declarations */
    enum RaffleState {
        OPEN,
        CALCULATING
    }
    /* State variables */
    uint256 private immutable i_entranceFee; // betti
    address payable[] private s_players; //pelaajalista
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator; // importattu koordinaattori
    bytes32 private immutable i_gasLane; // chainlinkin sivuilta
    uint64 private immutable i_subscriptionId; // chainlinkin sivuilta
    uint32 private immutable i_callbackGasLimit; // kaasuraja
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1; // pyydetään yksi satunnainen sana

    /* Lottery variables */

    address private s_recentWinner;
    RaffleState private s_raffleState; // loton tilanne
    uint256 private s_lastTimeStamp;
    uint256 private immutable i_interval;

    event RaffleEnter(address indexed player); // enter-tapahtuma
    event RequestedRaffledWinner(uint256 indexed requestId);
    event WinnerPicked(address indexed winner);

    constructor(
        address vrfCoordinatorV2,
        uint256 entranceFee,
        bytes32 gasLane,
        uint64 subscriptionId,
        uint32 callbackGasLimit,
        uint256 interval
    ) VRFConsumerBaseV2(vrfCoordinatorV2) {
        i_entranceFee = entranceFee;
        i_vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinatorV2);
        i_gasLane = gasLane;
        i_subscriptionId = subscriptionId;
        i_callbackGasLimit = callbackGasLimit;
        s_raffleState = RaffleState.OPEN;
        s_lastTimeStamp = block.timestamp;
        i_interval = interval;
    }

    function enterRaffle() public payable {
        if (msg.value < i_entranceFee) {
            // jos tarjoaa pienempää kuin betti, revert
            revert Raffle__NotEnoughETHEntered();
        }
        if (s_raffleState != RaffleState.OPEN) {
            // jos lotto ei ole auki, revert
            revert Raffle__NotOpen();
        }
        s_players.push(payable(msg.sender)); // lisätään pelaaja listaan
        emit RaffleEnter(msg.sender);
    }

    /**
     * @dev tätä chainlinkin nodet kutsuu
     * ne odottaa että "upkeepNeeded" on True.
     * Jotta se on totta:
     * 1. aikaintervallin pitää olla kulunut
     * 2. lotolla on ainakin yksi pelaaja ja ethiä
     * 3. subscription on maksettu LINKillä
     * 4. loton pitää olla "auki"
     */

    function checkUpkeep(
        bytes memory /* checkData */
    )
        public
        override
        returns (
            bool upkeepNeeded,
            bytes memory /* performData */
        )
    {
        bool isOpen = (RaffleState.OPEN == s_raffleState); // tarkastus että on auki
        bool timePassed = ((block.timestamp - s_lastTimeStamp) > i_interval); // totta jos tarpeeksi aikaa on kulunut
        bool hasPlayers = (s_players.length > 0);
        bool hasBalance = address(this).balance > 0;
        upkeepNeeded = (isOpen && timePassed && hasPlayers && hasBalance); // kaikki ok
    }

    function performUpkeep(
        bytes calldata /* performData */
    ) external override {
        (bool upkeepNeeded, ) = checkUpkeep(""); // passataan ed. funktiolle parametrit (tyhjä bytes)
        if (!upkeepNeeded) {
            revert Raffle__UpkeepNotNeeded(
                address(this).balance,
                s_players.length,
                uint256(s_raffleState)
            );
        }
        s_raffleState = RaffleState.CALCULATING; // lotto kiinni
        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            // syötetään requestRandomWords-funktiolle chainlink-docsien vaatimat parametrit
            i_gasLane, //gaslane
            i_subscriptionId, //chainlinkin sivuilta
            REQUEST_CONFIRMATIONS, // kuinka monta vahvistusta lohkoketjussa vaaditaan
            i_callbackGasLimit, //kaasun säätö
            NUM_WORDS //kuinka monta sanaa
        );
        // tämä emit on periaatteessa ylimääräinen koska se tulee myös requestRandomWOrds:sta
        emit RequestedRaffledWinner(requestId);
    }

    function fulfillRandomWords(
        uint256, /*requestId*/
        uint256[] memory randomWords
    ) internal override {
        uint256 indexOfWinner = randomWords[0] % s_players.length; // jakojäännös on satunnaisen osallistujan indeksiluku
        address payable recentWinner = s_players[indexOfWinner]; // voittajan osoite
        s_recentWinner = recentWinner; // laitetaan voittaja storageen
        s_raffleState = RaffleState.OPEN; // lotto on taas auki
        s_players = new address payable[](0); // pelaajalistan nollaus
        s_lastTimeStamp = block.timestamp; // lastTimeStampin päivitys
        (bool success, ) = recentWinner.call{value: address(this).balance}("");
        if (!success) {
            revert Raffle__TransferFailed();
        }
        emit WinnerPicked(recentWinner);
    }

    /* View / Pure functions */

    function getEntranceFee() public view returns (uint256) {
        return i_entranceFee;
    }

    function getPlayer(uint256 index) public view returns (address) {
        return s_players[index];
    }

    function getRecentWinner() public view returns (address) {
        return s_recentWinner;
    }

    function getRaffleState() public view returns (RaffleState) {
        return s_raffleState;
    }

    function getNumWords() public pure returns (uint256) {
        // ei lue storagesta, eli voi olla viewn sijaan pure
        return NUM_WORDS;
    }

    function getNumberOfPlayers() public view returns (uint256) {
        return s_players.length;
    }

    function getLatestTimeStamp() public view returns (uint256) {
        return s_lastTimeStamp;
    }

    function getRequestConfirmations() public pure returns (uint16) {
        return REQUEST_CONFIRMATIONS;
    }

    function getInterval() public view returns (uint256) {
        return i_interval;
    }
}
