Warning! Some features might not be fully implemented, or contain bugs! Feel free to make issues and contribute :)

# BeamMP Race System
**Authored by Beams of Norway**

A racing system for BeamMP servers featuring rally (time trial) and grid (multi-player) race modes with checkpoint tracking, leaderboards, and automated race management.

---

## 🎮 Features

### Race Modes
- **Rally Mode**: Individual time trials with staggered starts
- **Grid Mode**: Multi-player races with lobby system and simultaneous starts (Not fully tested or prioritized, feedbackand testing wanted...)

### Core Features
- ✅ **Automated Race Management**: Autoloader triggers for seamless race entry
- ✅ **Progressive Checkpoint System**: Checkpoints appear sequentially to reduce clutter
- ✅ **Jump Start Detection**: Penalizes players who start before the countdown ends
- ✅ **Personal Best Tracking**: Shows time differences against your best runs
- ✅ **Leaderboard System**: Persistent high scores with reset counting
- ✅ **Vehicle Reset Tracking**: Counts resets during races
- ✅ **Lobby System**: Grid races wait for players or timeout
- ✅ **Race Creation Tools**: In-game commands to create custom races

---

## 📁 File Structure

```
Resources/Server/RaceManager/
├── RaceScore.lua          # Leaderboard and scoring system
├── RallyCreator.lua       # Race creation and editing tools
├── RaceRunner.lua         # Main race logic and state management
├── Races/                 # Race configuration files (JSON)
│   └── raceConfig_*.json
└── RaceResults/           # Race results (JSON)
    └── run_*.json

Resources/Client/BonRaceClient.zip
├── lua/ge/extensions/
│   └── BonRaceClient.lua   # Client-side trigger handling and UI
└── scripts/BonRaceClient/
    └── modeScript.lua      # Loads the client script
```

---

## 🚀 Installation

### Server Setup

1. **Copy files to your BeamMP server:**
   ```
   Resources/Server/RaceManager/RaceScore.lua
   Resources/Server/RaceManager/RallyCreator.lua
   Resources/Server/RaceManager/RaceRunner.lua
   ```

2. **Create required directories:**
   ```
   Resources/Server/RaceManager/Races/
   Resources/Server/RaceManager/RaceResults/
   ```

### Client Setup

1. **zip and Copy client files:**
   ```
   Resources/Client/BonRaceClient.zip
   ```

### Dependencies

- **timeTools.lua**: Required for time formatting
  ```lua
  -- Place in: Resources/Server/Globals/timeTools.lua
  ```

---

## 🎯 Usage

### For Players

#### Joining Races
1. **Find available races:**
   ```
   /list
   ```

2. **Teleport to race start:**
   ```
   /tp <raceName>
   ```

3. **Enter the autoloader trigger** to join the race
   - **Rally Mode**: You'll be queued and teleported to start after countdown
   - **Grid Mode**: You'll join a lobby waiting for other players

#### During Races
- **Countdown**: 3-2-1-GO! appears on screen
- **Checkpoints**: Progress through checkpoints in order
- **Finish**: Cross the finish line to complete the race
- **Retire**: Use `/retire` to quit mid-race

#### Viewing Scores
```
/hs <raceName>
```
Shows top 15 times with reset counts.

#### Other Commands
```
/help          # Show available commands
/retire        # Quit current race
```

---

### For Race Creators

#### Creating a New Race

1. **Start race creation:**
   ```
   /newrace <raceName>
   ```
   This creates the first start position at your current location.

2. **Add more start positions** (for grid races):
   ```
   /start
   ```
   Position yourself where you want each grid slot.

3. **Add checkpoints:**
   ```
   /cp
   ```
   or
   ```
   /checkpoint
   ```
   Position yourself at each checkpoint location.

4. **Set finish line:**
   ```
   /end
   ```
   or
   ```
   /finish
   ```

5. **Configure race settings:**
   ```
   /laps <number>              # Set number of laps (default: 1)
   /startInterval <seconds>    # Time between race starts (default: 30)
   ```

6. **Add autoloader** (optional but recommended):
   ```
   /autoloader
   ```
1. Position yourself at autoloader location.
   Creates a trigger where players can join the race.

7. **Save the race:**
   ```
   /save
   ```

#### Managing Races

```
/cancel                    # Cancel current race creation
/deleteRace <raceName>     # Delete a race you created
```

#### Race Modes (Automatic)
- **Rally Mode**: Created when you have 1 start position
- **Grid Mode**: Created when you have 2+ start positions

---

## ⚙️ Configuration

### Race Template (JSON)

```json
{
  "name": "mountainPass",
  "creator": "beammp_user_id",
  "laps": 1,
  "startInterval": 30,
  "startPosition": [
    {
      "pos": {"x": 100, "y": 200, "z": 10},
      "rot": {"x": 0, "y": 0, "z": 0, "w": 1}
    }
  ],
  "checkPoints": [
    {
      "pos": {"x": 150, "y": 250, "z": 12},
      "rot": {"x": 0, "y": 0, "z": 0, "w": 1}
    }
  ],
  "finishPoints": {
    "pos": {"x": 200, "y": 300, "z": 15},
    "rot": {"x": 0, "y": 0, "z": 0, "w": 1}
  },
  "autoloaderPosition": {
    "pos": {"x": 50, "y": 150, "z": 8},
    "rot": {"x": 0, "y": 0, "z": 0, "w": 1}
  },
  "triggers": [...]
}
```

### Server Constants (RaceRunner.lua)

```lua
local DEFAULT_LOBBY_TIMEOUT = 15    -- Seconds before grid race auto-starts
local RESTART_HONK_WINDOW = 30      -- Seconds after finish to allow restart
local TICK_INTERVAL_MS = 1000       -- Server tick rate
local COUNTDOWN_LEAD = 3            -- Countdown duration in seconds
```

---

## 🔧 Technical Details

### Race Flow

#### Rally Mode
1. Player enters autoloader
2. Server schedules start time (respecting `startInterval`)
3. Player is teleported to start position
4. Countdown begins (3-2-1-GO)
5. Start trigger activates, timer begins
6. Checkpoints appear progressively
7. Finish trigger records time
8. Results saved to JSON

#### Grid Mode
1. Players enter autoloader and join lobby
2. Lobby waits for:
   - All grid slots filled, OR
   - Timeout after last player joined
3. All players teleported to grid positions
4. Simultaneous countdown
5. Race proceeds like rally mode
6. Each player's finish is recorded independently

### State Management

**Server-side tables:**
- `raceTemplates`: Cached race configurations
- `raceState`: Active race instances and lobbies
- `playerState`: Current player race status
- `mpUserIdToSenderId`: Player ID mapping

### Trigger Types

| Type | Color | Purpose |
|------|-------|---------|
| `start` | Green | Race start line |
| `cp` | Blue | Checkpoints |
| `finish` | Red | Finish line |
| `autoloader` | Yellow | Race entry point |

---

## 🔒 Security Notes

### Important Considerations
- Race names should be alphanumeric only (no special characters)
- Only race creators can delete their races
- Guest players have limited access to prevent abuse
- File paths are server-side only (no client access)

---

## 🤝 Contributing

### Reporting Issues
Please include:
- BeamMP server version
- Lua error messages (if any)
- Steps to reproduce
- Race configuration (if relevant)

### Code Style
- Use `camelCase` for functions
- Use `local` for all variables unless global is required
- Add comments for complex logic
- Test with both rally and grid modes

---

## 📝 License

This project is authored by **Beams of Norway**. Please respect the original authorship when modifying or redistributing.

---

## 🙏 Credits

**Author**: Beams of Norway  
**Platform**: BeamMP  
**Game**: BeamNG.drive

---

## 📞 Support

For issues, questions, or suggestions:
- Open an issue on GitHub
- Join the Beams of Norway Discord community

---

## 🎓 Examples

### Example: Creating a Simple Rally Race

```lua
-- 1. Position yourself at the start line
/newrace hillClimb

-- 2. Drive to checkpoint 1
/cp

-- 3. Drive to checkpoint 2
/cp

-- 4. Drive to finish line
/end

-- 5. Drive to where players should spawn
/autoloader

-- 6. Save the race
/save
```

### Example: Creating a Grid Race

```lua
-- 1. Position at grid slot 1
/newrace circuitRace

-- 2. Position at grid slot 2
/start

-- 3. Position at grid slot 3
/start

-- 4. Add checkpoints...
/cp
/cp

-- 5. Add finish
/end

-- 6. Add autoloader
/autoloader

-- 7. Configure
/laps 3
/startInterval 60

-- 8. Save
/save
```

---

## 🔍 Troubleshooting

### "Race not found" error
- Verify race name with `/list`
- Check that race JSON file exists in `Races/` folder
- Ensure no typos in race name

### Countdown doesn't start
- Check that you're signed in with BeamMP account (not guest)
- Verify autoloader trigger exists
- Check server console for errors

### Triggers not appearing
- Ensure client script is loaded
- Try `/fatalError` to reset all triggers (admin only)
- Check for Lua errors in console

### Leaderboard not updating
- Verify `RaceResults/` folder exists and is writable
- Check that race was completed (not retired)
- Ensure finish trigger was crossed

---

**Enjoy racing! 🏁**