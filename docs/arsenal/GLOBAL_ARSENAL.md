# Global Arsenal — Chump Fleet Codex

_Generated 2026-05-25T03:39:10Z by scripts/arsenal/build.py v0_

**Operator:** repairman29 (Jeff Adkins)
**GitHub repos:** 76  
**Cloned locally:** 11  
**Unmatched local roots:** 4

## 🚨 Alerts

- **[low] misplaced_clone** — Projects/ shouldn't itself be a git repo — likely an errant `git clone` at the wrong level. Move .git/ into the intended subdir or rm.
  - `/Users/jeffadkins/Projects`
- **[medium] stale_vendored_clone** — Maclawd contains a March 2026 clone of chump — Smart Harvest target: convert to git-submodule or Cargo dependency
  - `/Users/jeffadkins/Projects/Maclawd/chump-repo`

## Clusters

| Cluster | Count | Active (30d) | Languages |
|---|---:|---:|---|
| `smugglers-rpg` | 24 | 0 | JavaScript:20, TypeScript:2, CSS:2 |
| `content-apps` | 13 | 0 | TypeScript:6, JavaScript:3, HTML:2, Python:2 |
| `tools-platform` | 9 | 0 | JavaScript:5, TypeScript:1, HTML:1, Python:1, ?:1 |
| `echeo-resonant` | 8 | 0 | TypeScript:5, Rust:2, JavaScript:1 |
| `chump-engine` | 5 | 3 | Rust:2, Shell:1, Ruby:1, ?:1 |
| `misc` | 4 | 1 | ?:2, TypeScript:1, HTML:1 |
| `jarvis-assistant` | 4 | 0 | JavaScript:2, Shell:1, ?:1 |
| `political-strat` | 4 | 0 | Python:3, HTML:1 |
| `marketing-sites` | 2 | 0 | TypeScript:1, HTML:1 |
| `beast-mode-qi` | 2 | 0 | JavaScript:1, HTML:1 |
| `upshift-deps` | 1 | 0 | TypeScript:1 |

## Duplication Findings (DRY violations)

### `echeo-*`
**Variants:** echeo, echeovid, echeo-internal, echeo-archived, echeo_old, echeo-web, echeodev, echeo-dev  
**Recommendation:** consolidate to one active variant + archive the rest; pick the most recently pushed as primary

### `mythseeker-*`
**Variants:** mythseeker2, MythSeeker  
**Recommendation:** v1 vs v2 — pick survivor, archive other

### `smuggler-*`
**Variants:** smuggler, smugglers  
**Recommendation:** core vs full — clarify which is the active engine

### `coderoach/code-roach`
**Variants:** code-roach, coderoach  
**Recommendation:** rename collision — one is archived; archive the other or merge

### `project[-_]forge`
**Variants:** project-forge, project_forge  
**Recommendation:** underscore vs hyphen — both archived; collapse

### `2029-*`
**Variants:** project2029, 2029, 2029-versioned  
**Recommendation:** three repos for one initiative — pick one canonical

### `jarvis-*`
**Variants:** jarvis-gateway, JARVIS, JARVIS-Premium, jarvis-rog-ed  
**Recommendation:** platform variants (ROG Ally, Android, gateway, premium) — confirm intentional vs accidental fork

## Primitives Index (Smart-Harvest source candidates)

- **ai-generation** → neural-farm, code-generation-service, audio-generation-service, ai-gm-service
- **auth** → auth-platform-service
- **chat** → messaging-demo, chat-platform-service
- **ci-cd** → homebrew-chump
- **list-mgmt** → olive, trove-app, sheckleshare, trove-web
- **marketplace** → BEAST-MODE, beast-mode-website, economy-system-service, marketplace-system-service
- **payment** → postsub, commercial-platform, payment-platform-service
- **rpg-mechanic** → smuggler, mythseeker2, services-dashboard, service-frontends, mock-services, bot-simulation-service, commercial-platform, MythSeeker, combat-system-service, character-system-service, mission-engine-service, smugglers
- **video** → echeovid

## Cluster Deep-Dives

### smugglers-rpg
- **smuggler** [JavaScript] Core Smugglers RPG game - streamlined version without AI utilities
- **mythseeker2** [TypeScript] AI-powered tabletop RPG platform with 3D graphics - React/TypeScript/Vite frontend, Three.js for 3D, Firebase backend, OpenAI integration
- **analytics-platform-service** [JavaScript] Comprehensive game analytics and monitoring platform with real-time metrics and player behavior analysis
- **zendesk-background-agent** [JavaScript] 
- **services-dashboard** [CSS] Services Dashboard - Monitoring and management interface for Smuggler RPG enterprise platform
- **service-frontends** [CSS] Service Frontends - User interfaces and dashboards for Smuggler RPG microservices
- **mock-services** [JavaScript] Mock Services - Testing and development utilities for Smuggler RPG enterprise platform
- **bot-simulation-service** [JavaScript] Bot Simulation Service - AI-powered UI/UX testing and funnel analysis for Smuggler RPG enterprise platform
- **commercial-platform** [JavaScript] Commercial Platform Service - Business logic and monetization features for Smuggler RPG enterprise platform
- **internal-zendesk-tools** [JavaScript] 
- **MythSeeker** [TypeScript] AI Dungeon Master RPG with React, TypeScript, and Vite
- **auth-platform-service** [JavaScript] Enterprise authentication and security platform with DDoS protection and compliance features
- **combat-system-service** [JavaScript] Advanced combat mechanics and battle system for RPG games
- **character-system-service** [JavaScript] Character management system for RPG games with generation, progression, and crew management
- **mission-engine-service** [JavaScript] Dynamic mission and quest generation system
- **chat-platform-service** [JavaScript] Real-time chat and messaging system for games
- **payment-platform-service** [JavaScript] Complete payment processing and monetization system
- **economy-system-service** [JavaScript] Advanced in-game economy and market simulation system with dynamic pricing and trade mechanics
- **marketplace-system-service** [JavaScript] In-game marketplace with trading and auctions
- **code-generation-service** [JavaScript] AI-powered code generation and development tools
- **asset-management-service** [JavaScript] Digital asset management and content delivery
- **audio-generation-service** [JavaScript] AI-powered audio generation and sound management
- **smugglers** [JavaScript] Smugglers RPG - Main game implementation with full game mechanics and systems
- **ai-gm-service** [JavaScript] AI Game Master service for dynamic narrative generation and player interaction

### content-apps
- **pvc** [TypeScript] Peak Vinyl Club — members-only social club site and membership portal
- **slidemate** [TypeScript] JSX/MDX to Google Slides conversion tool with AI content generation and multi-platform SDKs - TypeScript with Google APIs and Generative AI
- **olive** [HTML] Olive - multi-user shopping list at shopolive.xyz
- **trove-app** [Python] Collection management platform for collectors - React/TypeScript/Vite frontend with Firebase backend, rules system, and collection tracking
- **postsub** [TypeScript] Content publishing platform with rich text editing, media studio, newsletter creation - React/TypeScript frontend with Firebase backend and Stripe payments
- **berry-avenue-codes** [JavaScript] A web app for Berry Avenue idle animation codes
- **dice** [TypeScript] 
- **mixdown** [Python] Audio recording & CD ripping software with AI metadata lookup and enhancement - Python/Flask application
- **coloringbook** [JavaScript] Interactive coloring book application with neural processing for AI-powered coloring - React frontend with Python/FastAPI backend
- **biomeweavers** [TypeScript] 
- **messaging-demo** [HTML] 
- **sheckleshare** [JavaScript] Enhanced Grow Garden Calculator - Comprehensive crop and pet management with real-time value calculations
- **trove-web** [TypeScript] Web interface for Trove collection management platform - Next.js/TypeScript with Firebase integration and Google Cloud Storage

### tools-platform
- **openclaw** [TypeScript] Your own personal AI assistant. Any OS. Any Platform. The lobster way. 🦞  📁 `/Users/jeffadkins/Projects/Maclawd` (dir renamed → `Maclawd`)
- **pixel-edge-server** [HTML]  📁 `/Users/jeffadkins/Projects` (dir renamed → `Projects`)
- **neural-farm** [Python] Local Neural Farm: MacBook + iPhone + Pixel, one API for Cursor (LiteLLM + InferrLM)
- **workbench** [JavaScript] 
- **slides** [?] 
- **daisy-chain** [JavaScript] AI-assisted development automation platform
- **code-roach** [JavaScript] Self-learning code quality platform that gets smarter with every fix
- **oracle** [JavaScript] Machine-readable knowledge layer for AI development tools
- **coderoach** [JavaScript] ARCHIVED · 

### echeo-resonant
- **echeo** [Rust] Echeo CLI - The Resonant Engine. Find where your code resonates with market needs. 📁 `/Users/jeffadkins/Projects/Echeo/echeo`
- **echeovid** [TypeScript] Video content creation platform with 7 personas, YouTube publishing, FFmpeg integration - React/TypeScript frontend with Firebase backend
- **echeo-internal** [Rust] Echeo - The Resonant Engine. Find where your code resonates with market needs.
- **echeo-archived** [JavaScript] 
- **echeo_old** [TypeScript] 
- **echeo-web** [TypeScript] Echeo Landing Page - The Resonant Engine
- **echeodev** [TypeScript] ARCHIVED · 
- **echeo-dev** [TypeScript] ARCHIVED · 

### chump-engine
- **chump** [Shell] PUBLIC · Self-hosted AI coding agent with persistent memory and bounded autonomy. Local-first, your keys, your data. Written in Rust. 📁 `/Users/jeffadkins/Projects/Chump`
- **homebrew-chump** [Ruby] PUBLIC · Homebrew tap for chump — auto-generated formula via cargo-dist (INFRA-172)
- **chump-proprietary** [Rust]  📁 `/Users/jeffadkins/Projects/chump-proprietary`
- **chump-chassis** [Rust] Rust/Axum micro-SaaS boilerplate for Chump SaaS factory 📁 `/Users/jeffadkins/Projects/Chump/repos/repairman29_chump-chassis` (dir renamed → `repairman29_chump-chassis`) [nested-in-Chump]
- **chump-brain** [?]  📁 `/Users/jeffadkins/Projects/Chump/chump-brain` [nested-in-Chump]

### misc
- **registry** [?] FORK · PUBLIC · Registry of agents implementing the Agent Client Protocol (ACP)
- **okr** [?] 
- **project-forge** [TypeScript] Echeo - A modern project management platform
- **project_forge** [HTML] ARCHIVED · 

### jarvis-assistant
- **jarvis-gateway** [Shell] 
- **JARVIS** [JavaScript] AI-powered conversational productivity system with natural language workflow automation
- **JARVIS-Premium** [?] 💎 JARVIS Premium Skills - Professional AI-powered productivity tools for teams and enterprises
- **jarvis-rog-ed** [JavaScript] JARVIS ROG Ed. - AI assistant for ASUS ROG Ally (Windows 11) 📁 `/Users/jeffadkins/Projects/jarvis-rog-ed`

### political-strat
- **project2029** [Python] Project 2029 aims to create a more equitable, democratic, and rights-centered America that prioritizes individual liberties, economic fairness, peaceful international relations, and human rights.
- **2029** [Python] My 2029 Project Folder
- **2029-versioned** [Python] Putting my versioning approach together and still figuring out how repo's work
- **ims** [HTML] 2029 Initiative Tracker - Strategic initiative management system with Flask/Python backend, dashboard, and RESTful API

### marketing-sites
- **acg** [TypeScript] Adkins Consulting Group LLC — internal docs and acgllc.dev marketing site (Next.js in web/) 📁 `/Users/jeffadkins/Projects/ACG`
- **repairman29-website** [HTML] Website for repairman29

### beast-mode-qi
- **BEAST-MODE** [JavaScript] Enterprise Quality Intelligence & Marketplace Platform - The world's most advanced AI-powered development ecosystem 📁 `/Users/jeffadkins/Projects/BEAST-MODE`
- **beast-mode-website** [HTML] BEAST MODE - Enterprise Quality Intelligence & Marketplace Platform Landing Page

### upshift-deps
- **upshift** [TypeScript] AI-powered dependency upgrades. Stop reading changelogs—let AI tell you what breaks. 📁 `/Users/jeffadkins/Projects/upshift`

## Unmatched Local Git Roots (no GitHub origin / third-party / accidental)

- `/Users/jeffadkins/Projects/Chump/repos/axonerai` → https://github.com/Manojython/axonerai.git
- `/Users/jeffadkins/Projects/Chump/repos/repairman29_beast-mode` → https://github.com/repairman29/beast-mode.git
- `/Users/jeffadkins/Projects/Maclawd/chump-repo/chump-brain` → (no remote)
- `/Users/jeffadkins/Projects/Maclawd/chump-repo` → https://github.com/repairman29/chump.git
