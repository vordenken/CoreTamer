# language: en
Feature: Limit the CPU usage of your own applications
  As a user I want to limit CPU-intensive processes
  without needing administrator rights or Rosetta.

  Scenario: The interface follows the language selected in macOS
    Given German is the preferred language for CoreTamer in macOS
    When I open CoreTamer
    Then the process category is labelled "Hintergrundprozesse"
    And the app scope is labelled "Gesamte App"
    And the update speed is labelled "Schnell (1 s)"
    When I change CoreTamer's preferred language to English in macOS
    Then the process category is labelled "Background processes"
    And the app scope is labelled "Entire app"

  Scenario: The first launch shows a welcome
    Given CoreTamer has never been launched before
    When CoreTamer starts
    Then the CoreTamer popover opens
    And it shows "Welcome to CoreTamer"
    And it offers "Launch at login" and "Check for updates automatically"
    When I choose "Get Started"
    Then the welcome is hidden
    And it is not shown again on the next launch

  Scenario: A scheduled update has a gentle reminder
    Given CoreTamer is running in the menu bar
    And Sparkle finds an update during a scheduled check without immediate focus
    Then the menu bar icon indicates that an update is available
    When I open the CoreTamer popover
    Then it shows "Version 1.0.1 is available"
    And it shows "Show Update…"
    When I choose "Show Update…"
    Then Sparkle shows its standard update interface

  Scenario Outline: A single process gets a measurable CPU limit
    Given one of my processes uses about one CPU core
    When I set its limit to <Limit> percent
    Then its measured CPU usage is between <Minimum> and <Maximum> percent
    And after removing the limit it can use more CPU time again

    Examples:
      | Limit | Minimum | Maximum |
      | 20    | 13      | 26      |
      | 50    | 32.5    | 65      |

  Scenario: A limit can span several CPU cores
    Given one of my processes keeps four threads busy
    When I set its limit to 150 percent
    Then its measured CPU usage is between 120 and 180 percent

  Scenario: Choose the main process or a shared budget
    Given I select an app row that has helper processes
    Then "Main process only" is preselected when no group limit exists
    When I choose "Entire app" and apply 50 percent
    Then the combined CPU usage of all members is between 32 and 68 percent
    And the app limit is labelled "total"
    And its helpers show "Shared"
    When another helper process is detected on the next process refresh
    Then the shared limit stays at 50 percent in total
    And helper processes that have exited are no longer limited
    And membership is updated even while the display is paused
    When a helper process is protected or was stopped externally
    Then it is skipped and the shared limit stays active

  Scenario: Reject overlapping limits
    Given a helper process already has an individual limit
    When I try to apply a shared app limit
    Then I am asked to remove the existing limit first
    And no process is limited by two controllers at the same time
    When the app has a shared limit instead
    Then I cannot additionally limit one of its helpers individually

  Scenario: An individual process has an explicit target without a scope selector
    Given I expand the "Code" app group and select its "yes" process
    Then the inspector shows "Individual process · Part of Code" and the selected PID
    And neither "Entire app" nor "Main process only" is offered
    And the limit applies only to the selected "yes" PID
    When I click "Select Code app group"
    Then the "Code" app row is selected without applying or removing any limit
    And I can choose between "Entire app" and "Main process only"
    And searching for a helper does not change which app group it belongs to

  Scenario: A covered helper shows its shared budget instead of individual controls
    Given "Code" has a shared app limit of 50 percent
    When I select one of its helper processes
    Then the inspector shows "Included in Code's shared 50% limit."
    And individual limit controls and the scope selector are hidden
    And I can click "Select Code app group" to manage the shared limit

  Scenario: Settings and the limit inspector do not compete for space
    Given I have selected a process row and its inspector is visible
    When I open settings using the gear button
    Then the limit inspector is hidden
    And selecting a different process does not show the inspector while settings are open
    When I close settings using the gear button
    Then the inspector shows the currently selected process

  Scenario: Restore a group limit after a relaunch
    Given restoring limits is turned on
    And an app has a shared limit for its main process and helpers
    When the app starts with a new process identity
    Then the percentage and the shared scope are restored

  Scenario: The group watchdog resumes all stopped members
    Given a shared CPU controller has stopped two test processes
    When the controller is terminated with SIGKILL or SIGTERM
    Then both test processes continue running

  Scenario: Pause and resume all limits
    Given one of my processes has an active limit
    When I pause all limits
    Then the process runs without throttling
    And the configured limit stays saved
    When I resume the limits
    Then the configured limit is applied again

  Scenario: Invalid input does not change an existing limit
    Given one of my processes has a limit of 25 percent
    When I apply an invalid percentage
    Then I see an error message
    And the limit stays at 25 percent

  Scenario: A crashed controller leaves no stopped process behind
    Given CoreTamer has temporarily stopped one of my test processes
    When the CPU controller is terminated with SIGKILL
    Then the independent watchdog resumes the test process

  Scenario: Already stopped and foreign processes stay untouched
    Given a process belongs to another user or was already stopped
    When I try to apply a limit
    Then control is refused
    And the process receives no continue signal from CoreTamer

  Scenario: A reused process ID is not a process identity
    Given the start time of a selected process has changed
    When I try to apply its limit
    Then I have to select the new process again

  Scenario: Create a universal build
    When I run the build
    Then the app and its CPU controller each contain arm64 and x86_64

  Scenario: Restore an app limit after the app relaunches
    Given the optional restoring of limits is turned on
    And one of my apps has a limit of 50 percent
    When the app quits and starts with a new process identity
    Then the limit is restored based on its executable path
    When I remove the limit
    Then it is not applied automatically again

  Scenario: Sort the process list by clicking the column headers
    Given the process list is sorted by CPU usage in descending order by default
    When I click the "Name" column header
    Then the list is sorted alphabetically in ascending order
    When I click the "Name" column header again
    Then the list is sorted in descending order
    When I click the "PID" column header
    Then the list is sorted by process ID in ascending order
    When I click the "Limit" column header
    Then limited processes with the highest limit come first
    And processes without a limit follow

  Scenario: Click the selected process row again
    Given I have selected a process row
    When I click the same row again without a modifier key
    Then it is deselected and the inspector closes
    And this also applies to a quick second click
    And this also applies to the first app row with helpers while its inspector is open
    And this works with and without grouping by type
    And disclosure triangles and column headers keep their existing behavior

  Scenario: Take the version from semver.txt
    Given the first line of semver.txt contains "1.0.0"
    When I run the build
    Then the app shows version 1.0.0
    And an invalid version entry aborts the build with an error message

  Scenario: Group processes by type like Task Manager
    Given "Group by type (apps, background, system)" is turned on
    And background and system processes are shown
    Then I see the sections "Apps", "Background processes" and "System & other users" with their counts
    And apps with a Dock icon are listed under "Apps"
    And menu bar apps and helper services without an app are listed under "Background processes"
    And processes of other users and of root are listed read-only under "System & other users"
    And sorting applies within each section
    When I turn off "Group by type (apps, background, system)"
    Then I see one combined list without sections

  Scenario: Fold helper processes under their app
    Given an app has helper processes that macOS attributes to it (for example Safari's WebKit processes), that live in its app bundle or that it launched
    Then they appear collapsed under the app together with the total number of processes
    And this also applies when macOS reports the WebKit helpers as separate background applications
    And the app's CPU value is the sum of the app and its helper processes
    And the limit column shows how many helper processes are limited
    When I expand the app
    Then I can select and limit each helper process individually
    When I search for the name of a helper process
    Then the app appears with only the matching helper processes

  Scenario: The CPU display stays calm and readable
    Given the list is sorted by CPU usage
    When the CPU usage of the processes keeps changing
    Then the displayed values are exponentially smoothed with a time constant of five seconds
    And they are shown as whole percents with a subtle color highlight depending on the load
    And the actual CPU limiting is unaffected

  Scenario Outline: Choose the update speed
    When I choose the update speed "<Speed>"
    Then the list is <Behavior>
    And existing limits stay active

    Examples:
      | Speed        | Behavior                     |
      | Fast (1 s)   | refreshed every second       |
      | Normal (2 s) | refreshed every two seconds  |
      | Slow (5 s)   | refreshed every five seconds |
      | Paused       | no longer refreshed          |

  Scenario: Optionally pause the list while pointing at it
    Given "Pause list while pointing at it" is turned off
    When I point at the list or select a process
    Then the list keeps refreshing and re-sorting on every update
    And the selection stays highlighted even if the row moves
    When I turn the setting on and point at the list
    Then CPU values and order are no longer refreshed
    And a hint shows that the list is paused
    And existing limits stay active
    And clicking a column header still sorts immediately
    When I move the pointer away from the list
    Then the list refreshes again

  Scenario: Receive updates via Sparkle
    Given CoreTamer runs as a published app
    When I open the settings
    Then I can toggle automatic update checks, automatic downloads and beta versions individually
    And turning off the checks also turns off automatic downloads
    And turning on the downloads also turns on the checks
    And "Check Now…" checks for a new version immediately
    And beta versions are only offered when I have turned them on
