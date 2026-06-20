# Release Forge

Automatically creates and maintains **Release** work items in Azure DevOps by aggregating Features and Defects that share the same release date. Runs on a schedule (every 30 minutes) and supports both **Azure DevOps Pipelines** and **GitHub Actions**.

---

## How it works

1. For each team defined in `teamMappings.json`, queries all Features and Defects whose release date field is set.
2. Groups them by release date.
3. For each group, finds or creates a Release work item titled `[Team Name] - YYYY-MM-DD`.
4. Keeps the Release up to date: description, assignee, delivery team, linked items, and status.
5. Removes links to items that have moved to a different release date.
6. Skips Release work items that are already in **Done** state.

---

## Repository structure

```
scripts/
├── Common.ps1             Generic utilities (date conversion, batched fetch, sanitisation, token resolution)
├── Delivery.Logic.ps1     Business logic (description builder, state evaluator, sync engine)
├── Delivery.Main.ps1      Entry point — parameters, setup, loads mappings, runs sync loop
└── teamMappings.json      Team-to-area-path mappings

sync-releases.yml                      Azure DevOps pipeline definition
.github/workflows/sync-releases.yml      GitHub Actions workflow definition
```

---

## Required Azure DevOps custom fields

The automation reads from and writes to the following fields. All fields must exist in the process template before running the sync. Fields marked **read** are only queried; fields marked **write** are set by the sync.

> **Note:** The CI platform (Azure DevOps Pipelines or GitHub Actions) only runs the scripts — all work item data lives in Azure DevOps regardless of which CI system is used. There are no GitHub-specific fields.

### Feature work item

| Field reference | Display name | Type | Access | Purpose |
|---|---|---|---|---|
| `Custom.Release` | Release | Picklist (string) | Read | Release date the Feature is planned for. Values must follow the `dd-MMM-yy` format (e.g. `22-Jun-25`). Used to group Features into Release work items. |
| `Custom.BusinessValues` | Business Values | HTML / Plain text | Read | Business justification shown in the Release description. Configurable via the `businessJustificationField` parameter. |
| `Custom.InitiativeID` | Initiative ID | Plain text | Read | Initiative identifier used to generate a deep link to the ticketing system (e.g. ServiceNow). |
| `Custom.PointofContactSponsor` | Point of Contact / Sponsor | Plain text | Read | Sponsor name shown in the Release description. |
| `Microsoft.VSTS.Common.Priority` | Priority | Integer (1–4) | Read | Used to sort Features within the Release description. Priority 1 appears first. |

### Defect work item

| Field reference | Display name | Type | Access | Purpose |
|---|---|---|---|---|
| `Custom.Release` | Release | Picklist (string) | Read | Release date the Defect is planned for. Same format and values as Feature. |
| `Custom.ReferenceNumber` | Reference Number | Plain text | Read | Incident or defect number used to generate a deep link to the ticketing system. |
| `Microsoft.VSTS.Common.Priority` | Priority | Integer (1–4) | Read | Used to sort Defects within the Release description. Priority 1 appears first. |

### Release work item

| Field reference | Display name | Type | Access | Purpose |
|---|---|---|---|---|
| `Custom.Release` | Release | Picklist (string) | Write | Set to the same picklist value as the grouped Features/Defects (e.g. `22-Jun-25`). Must share the same picklist as Feature and Defect. |
| `Custom.ReleaseDate` | Release Date | Date | Write | Set to the converted date in `YYYY-MM-DD` format. Required field on the Release work item type. |
| `Custom.DeliveryTeam` | Delivery Team | Picklist (string) | Write | Set to the `teamName` from `teamMappings.json`. Must match an existing picklist value (see valid values below). |

#### Valid values for `Custom.DeliveryTeam`

- Apps
- ERP
- Integrations
- Portals
- Power Platform
- D365
- ServiceNow

### System fields written to Release work items

These are standard Azure DevOps fields — no custom configuration required.

| Field reference | Purpose |
|---|---|
| `System.Title` | Set to `[Team Name] - YYYY-MM-DD` |
| `System.Description` | Structured HTML release notes |
| `System.AreaPath` | Set to the team area path from `teamMappings.json` |
| `System.AssignedTo` | Set to the assignee email from `teamMappings.json` |
| `System.State` | Managed automatically (see state transition rules) |

---

## Parameters

All parameters are passed to `Delivery.Main.ps1` at runtime by the pipeline.

| Parameter | Description | Example |
|---|---|---|
| `organisation` | Azure DevOps organisation name | `[DevopsOrganizationName]` |
| `project` | Azure DevOps project name (spaces supported) | `[DevopsProjectName]` |
| `mappingsFile` | Absolute path to `teamMappings.json` | `$(Build.SourcesDirectory)/scripts/teamMappings.json` |
| `releaseDateField` | Internal field name of the release date picklist | `Custom.Release` |
| `releaseWit` | Work item type name for Release items | `Release` |
| `businessJustificationField` | Internal field name for the business justification | `Custom.BusinessValues` |
| `ticketingSystemBaseUrl` | Base URL of the external ticketing system used for deep links | `https://[ServiceNowInstanceName].service-now.com` |

---

## Team mappings

`scripts/teamMappings.json` defines which teams to sync. Add one entry per team.

```json
[
  {
    "areaPath":   "[DevopsOrganizationName]\\[DevopsTeamAreaPath]",
    "teamName":   "[TeamName]",
    "assignedTo": "[TeamManagerDomainUser]"
  },
  {
    "areaPath":   "The Amazig Aventures\\Spiderman",
    "teamName":   "Power Platform",
    "assignedTo": "peter.parker@TheAmazingAventures.com"
  }
]
```

| Field | Description |
|---|---|
| `areaPath` | Full Azure DevOps area path for the team. Use `\\` as separator. |
| `teamName` | Friendly team name. Used as the Release title prefix and written to `Custom.DeliveryTeam`. Must match an existing picklist value. |
| `assignedTo` | Email address of the person the Release work item is assigned to. |

---

## Description format

The Release description is generated as structured HTML release notes:

```
[Team Name]
Release date: YYYY-MM-DD
─────────────────────────────
This release includes N feature(s) and N defect(s).
─────────────────────────────
Features  (sorted by priority, highest first)
  • Title
    Business justification
    Initiative Number: <link to ticketing system>
    Sponsor: name

Defects  (sorted by priority, highest first)
  • Title
    Incident Number: <link to ticketing system>
```

All field content is sanitised before rendering: HTML entities are decoded, tags stripped, and non-printable characters removed.

---

## State transition rules

The sync evaluates the state of all linked Features and Defects on every run and updates the Release state accordingly.

| Condition | Release state set to |
|---|---|
| Release is already **Done** | Skipped entirely — no changes made |
| All non-cancelled items are **Done** | **Done** |
| At least one item is in an active state (see below) | **In Progress** |
| All items are in a planned/pre-work state | Unchanged |

**Active states** (trigger → In Progress):

| Feature | Defect |
|---|---|
| In Progress | In Progress |
| In IST | In Test |
| In QA test | In UAT |
| In UAT | Ready for Deployment |
| Live in Hypercare | |
| Ready for Deployment | |

**Planned states** (leave Release unchanged):

| Feature | Defect |
|---|---|
| New | New |
| Refinement | Refinement |
| Approved | On Hold |
| On Hold | Approved |
| | Committed |

**Ignored states** (excluded from all evaluation):

| Feature | Defect |
|---|---|
| Cancelled | — |

**Committed** is a manually managed state set by the team manager after aligning with stakeholders. The sync never sets or clears it.

---

## Stale link removal

If a Feature or Defect is reassigned to a different release date, the sync automatically removes its link from the old Release work item and adds it to the new one on the next run.

Work items must never be manually added to a Release that is already in **Done** state. The sync will not touch Done releases under any circumstances.

---

## Azure DevOps setup

### 1. Pipeline permissions

Enable **Allow scripts to access the OAuth token** on the pipeline (or agent job) so that `$(System.AccessToken)` is available.

### 2. Pipeline variables

All variables are defined in `sync-releases.yml`. Update them to match your environment:

```yaml
variables:
  organisation:               '[DevopsOrganizationName]'
  project:                    '[DevopsProjectName]'
  releaseDateField:           'Custom.Release'
  releaseWit:                 'Release'
  businessJustificationField: 'Custom.BusinessValues'
  ticketingSystemBaseUrl:     'https://[ServiceNowInstanceName].service-now.com'
```

### 3. Token env var

The pipeline passes `$(System.AccessToken)` as the `SYSTEM_ACCESSTOKEN` environment variable. The script resolves it automatically.

```yaml
env:
  SYSTEM_ACCESSTOKEN: $(System.AccessToken)
```

### 4. Schedule

The pipeline runs every 30 minutes on the `main` branch. The `always: true` flag ensures it runs even when there are no new commits.

```yaml
schedules:
- cron: '*/30 * * * *'
  displayName: 'Every 30 minutes sync'
  branches:
    include:
    - main
  always: true
```

---

## GitHub Actions setup

### 1. Create a Personal Access Token (PAT)

Create an Azure DevOps PAT with the following scopes:

- **Work Items**: Read & Write

Store it as a repository secret named `ADO_PAT`.

### 2. Repository variables

Create the following repository variables (Settings → Secrets and variables → Actions → Variables):

| Variable | Example value |
|---|---|
| `ORGANISATION` | `[DevopsOrganizationName]` |
| `PROJECT` | `[DevopsProjectName]` |
| `RELEASE_DATE_FIELD` | `Custom.Release` |
| `RELEASE_WIT` | `Release` |
| `BUSINESS_JUSTIFICATION_FIELD` | `Custom.BusinessValues` |
| `TICKETING_SYSTEM_BASE_URL` | `https://[ServiceNowInstanceName].service-now.com` |

### 3. Token env var

The workflow passes the PAT as the `ACCESS_TOKEN` environment variable. The script resolves it automatically.

```yaml
env:
  ACCESS_TOKEN: ${{ secrets.ADO_PAT }}
```

### 4. Schedule

The workflow runs every 30 minutes and can also be triggered manually via `workflow_dispatch`.

---

## Token resolution

The script automatically resolves the access token in priority order:

1. `ACCESS_TOKEN` — set by GitHub Actions
2. `SYSTEM_ACCESSTOKEN` — set by Azure DevOps Pipelines

If neither is set, the script exits with an error.

---

## Ticketing system deep links

The `ticketingSystemBaseUrl` parameter is the base URL for deep links rendered in the Release description. The paths used are:

| Item type | Path |
|---|---|
| Feature (Initiative) | `now/nav/ui/classic/params/target/x_u4bsh_initiati_0_initiative_list.do?sysparm_query=number=<ID>` |
| Defect (Incident) | `now/nav/ui/classic/params/target/rm_defect_list.do?sysparm_query=number=<ID>` |

To point to a different ticketing system, update `ticketingSystemBaseUrl` and adjust the path fragments inside `Delivery.Logic.ps1` in the `Format-Features` and `Format-Defects` functions.

---

## Adding a new team

1. Open `scripts/teamMappings.json`.
2. Add a new entry with the team's `areaPath`, `teamName`, and `assignedTo`.
3. Commit and push. The next scheduled run will pick it up automatically.

No changes to the scripts or pipeline are required.

---

## Author

**Victor Freire**

| | |
|---|---|
| GitHub | [github.com/viktorfreire](https://github.com/viktorfreire) |
| LinkedIn | [linkedin.com/in/viktorfreire](https://www.linkedin.com/in/viktorfreire) |
| Website | [viktorfreire.servehttp.com](https://viktorfreire.servehttp.com/) |

---

## Licence

MIT License

Copyright (c) 2026 Victor Freire

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
