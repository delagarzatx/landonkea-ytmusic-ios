# landonkea-ytmusic-ios — Design & Workflow

## High-Level Overview

```mermaid
graph TB
    subgraph "YTMusicAPI"
        A[InnerTubeClient] --> B[InnerTubeModels]
        A --> C[YouTube InnerTube API]
    end

    subgraph "YTMusicApp"
        D[YTMusicApp.swift] --> E[Views]
        D --> F[Services]
        D --> G[ViewModels]
    end

    subgraph "Views"
        E --> H[ContentView]
        E --> I[HomeView]
        E --> J[SearchView]
        E --> K[PlayerView]
    end

    subgraph "Services"
        F --> L[AudioPlayer]
        F --> M[CloudKitSyncManager]
    end

    A --> D
```

## Playback Flow

```mermaid
sequenceDiagram
    participant U as User
    participant V as ViewModel
    participant A as API Client
    participant P as Audio Player
    participant Y as YouTube

    U->>V: Search for song
    V->>A: search(query)
    A->>Y: InnerTube search
    Y-->>A: Search results
    A-->>V: Song list
    V-->>U: Display results

    U->>V: Tap song to play
    V->>A: Get streaming URL
    A->>Y: InnerTube player
    Y-->>A: Streaming URL
    A-->>V: URL
    V->>P: Play audio
    P-->>U: Music plays
```

## CloudKit Sync Flow

```mermaid
flowchart TD
    A[Local change] --> B[Encode to CKRecord]
    B --> C[Pull remote changes]
    C --> D[Merge conflicts]
    D --> E[Push merged state]
    E --> F[Other devices receive]
```

## File Relationships

| File | Purpose | Used By |
|------|---------|---------|
| `Sources/YTMusicAPI/InnerTubeClient.swift` | API client | Views |
| `Sources/YTMusicApp/YTMusicApp.swift` | App entry | iOS |
| `Sources/YTMusicApp/Services/AudioPlayer.swift` | Playback | Views |
| `Sources/YTMusicApp/Services/CloudKitSyncManager.swift` | iCloud sync | Models |
| `Sources/YTMusicApp/Views/` | UI components | App |
| `Tests/` | Unit tests | xcodebuild |

## draw.io

[Open in draw.io](https://app.diagrams.net/#RYTMusic%20architecture)
