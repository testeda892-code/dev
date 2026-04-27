// =============================================================================
// Spacecraft mission context — Logically Integrated Model
// — Avionics Integrated Use Case update
// =============================================================================
//
// LOGICAL ARCHITECTURE OF THE MERGE
// -----------------------------------
// The two source files are complementary viewpoints of the same system:
//
//   10.0  → Physical architecture: hardware decomposition, IBD connectivity,
//            action-flow pipeline (Collect And Downlink Observation Data),
//
//   v1    → Mission architecture: requirements, use cases, actors, and
//            behavioural attributes that DRIVE the physical architecture.
//
// The logical bridge is established through four mechanisms:
//
//   1. SPECIALISATION  — Mission part defs specialise (:>) the corresponding
//      physical part defs from 10.0. decomposition:
//        MissionGNCSubsystem    :> GNCSubsystem        — "navigation & pointing";
//                                                         contains ACSSubsystem
//                                                         as internal execution arm
//          └─ ACSSubsystem (nested) — owns nadir pointing (L2-REQ-002) and
//                                     all Demo 2 manoeuvring/torque calculations
//        MissionCDHSubsystem    :> AvionicsSubsystem   — OBC + CDH + TT&C
//                                                         "thinking & talking" hw;
//                                                         owns L2-REQ-030-044
//        MissionTTCSubsystem    :> CommunicationsSubsystem — TT&C uplink/downlink
//                                                         chain; owns L2-REQ-050-054
//        MissionEPSSubsystem    :> PowerSubsystem      — receives power draw from
//                                                         GNC(ACS)
//        MissionSpacecraft      :> SpacecraftPhysical  — SoI mission composite
//
//   2. REQUIREMENT ALLOCATION — Each requirement group carries a 'subject'
//      that points to the owning physical or mission part.
//
//   3. USE-CASE-TO-ACTION BINDING — Use case 'perform' steps reference the
//      named actions in the SpacecraftPhysical action pipeline. extends
//      Demo 2 with a 4-phase interaction flow:
//        Phase 1 — Command    : Ground → TT&C → OBC.parseAndDispatch → GNC(ACS)
//        Phase 2 — Execution  : GNC calculates; ACS computes torque; GNC → EPS
//        Phase 3 — Observation: GNC(ACS) → CDH HIGH_RATE; Science data stored
//        Phase 4 — Reporting  : CDH → TT&C → Ground (Science_Data_Packet +
//                                             Recorder_Occupancy_Status)
//
//   4. ACTOR-TO-EXTERNAL-ELEMENT MAPPING — Use case actors cross-referenced to
//      10.0 external packages.  ScienceInstrument added as new actor.
//
// CHANGES (from Avionics_Integrated_Use_Case.docx):
//   - MissionGNCSubsystem: ACSSubsystem added as nested part def; GNC owns
//     propagation (L2-REQ-060) and coverage math (L2-REQ-010/014)
//   - ACSSubsystem (new): nadir pointing, slew manoeuvres, classification tags
//   - MissionCDHSubsystem: OBC parseAndDispatch action added; doc updated to
//     reflect OBC + CDH + TT&C scope (Avionics = "thinking and talking" hw)
//   - MissionCommsSubsystem renamed to MissionTTCSubsystem: owns full uplink/
//     downlink chain; receiveUplink + transmitHealthTelemetry actions added
//   - MissionSpacecraft: comms :>> replaced by ttc :>>; obc stub added
//   - Use cases: gnc.classifyEnvironment → gnc.acs.classifyEnvironment;
//     comms.* → ttc.*; Demo 2 command phase + 4-phase flow added
//   - Requirements: doc text updated for L2-REQ-002, 020-023, 042, 050-054,
//     060; subject bindings updated
//   - ScienceInstrument: new external actor part def (OI-09)
// 4-BEHAVIOR (Addition — fully elaborated):
//   - 'SDA State Machine' package: state def SpacecraftMissionSM with 6 states
//       SAFE (merged SAFE+SAFE_RECOVERY), IDLE, NADIR_ACQUISITION,
//       MANOEUVRING, TARGET_TRACKING, DOWNLINK
//     and 13 transitions (incl. global SoC override * -> SAFE).
//   - 'SDA Actions' package: 6 atomic action defs + 2 pipeline action defs:
//       DataAcquisitionPipeline  — 5-step sequential (computeSwath →
//         classifyEnvironment → selectDataRate → updateStorage →
//         updateCoverageGrid)
//       Demo2ManoeuvreSequence   — 4-step slew pipeline (computeTorque →
//         slewToTarget → activateHighRateObservation → slewToNadir)
// =============================================================================

package 'Spacecraft Mission — Integrated' {

    // =========================================================================
    // 1-Requirements
    // All L2 + Demo 2 requirements for the SDA mission.
    // =========================================================================
    package '1-Requirements' {
        public import 'Spacecraft Mission — Integrated'::'2-Structure'::'Mission Types'::*;
        public import 'Spacecraft Mission — Integrated'::'6-Spacecraft'::'Physical Architecture'::'4-Subsystems'::'Mission Subsystems'::*;

        requirement def SpacecraftDataAcquisitionRequirements {
            doc /* L2 + Demo 2 requirements for the SDA mission.
                 * Subject: MissionSpacecraft (750 km SSO, 6 PM node).
                 * Physical satisfaction allocated to subsystems in Physical Architecture.
                 * now at top-level 'Spacecraft Mission — Integrated' > '1-Requirements'. */

            subject spacecraft : MissionSpacecraft;

            // ── Scenario Setup 

            requirement <'L2-REQ-001'> orbitDefinition {
                doc /* The system shall support defining a sun-synchronous
                     * orbit scenario with altitude 750 km and 6 PM
                     * descending node.
                     * Satisfied by: attribute Orbit on Spacecraft (2-Structure). */
            }
            // This requirement needs to be updated since it was on
            requirement <'L2-REQ-002'> nadirOnlyPointing {
                doc /* The system shall maintain nadir-only pointing for Demo 1.
                     * Satisfied by GNCSubsystem > ACSSubsystem.setNadirMode.
                     * ACS is nested within GNC as its execution arm.
                     * Physical ports: 'star tracker i/f', 'horizon tracker i/f'. */
                require constraint {
                    spacecraft.gnc.acs.acs_mode == ACSMode::NADIR
                }
            }

            requirement <'L2-REQ-003'> instrumentAlwaysOn {
                doc /* The instrument shall be modelled as powered on
                     * continuously for the simulation duration.
                     * Satisfied by: Payload Subsystem > Payload Sensor (always active). */
            }

            requirement <'L2-REQ-004'> groundSegmentBaseline {
                doc /* The system shall configure a 9-station baseline ground
                     * segment for downlink trade studies.
                     * Satisfied by: '7-Ground Station' (9 stations, 10° elevation mask).
                     * Actor GroundStationNetwork interfaces via TT&C uplink/downlink chain. */
                require constraint {
                    spacecraft.ttc.tel_stationId != ""
                }
            }

            // ── Swath Geometry & Coverage ──────────────────────────────
            // Physical owner: GNCSubsystem ( GNC owns propagation
            // + coverage/swath math; ACS executes computeSwath)

            requirement <'L2-REQ-010'> swathGeometry {
                doc /* Compute swath footprint from altitude and FOV.
                     * Satisfied by GNCSubsystem > ACSSubsystem.computeSwath
                     *   (acs_fov_deg=60°, acs_altitude_km=750 km → acs_swathKm).
                     * GNC owns swath/coverage math per decomposition. */
            }

            requirement <'L2-REQ-011'> swathContinuousUpdate {
                doc /* Update swath footprint at each propagation step.
                     * Satisfied by: CDH updateCoverageGrid called per time step. */
            }

            requirement <'L2-REQ-012'> globalCoverageGrid {
                doc /* Maintain global land+ocean surface coverage grid.
                     * Satisfied by: CDH updateCoverageGrid (cdh_envClass tracking). */
            }

            requirement <'L2-REQ-013'> cellMarkingRule {
                doc /* Mark cells covered when intersecting swath footprint.
                     * Satisfied by: CDH updateCoverageGrid intersection logic. */
            }

            requirement <'L2-REQ-014'> globalCoveragePercent {
                doc /* Compute and report percent global coverage.
                     * Satisfied by: MissionSpacecraft.mission_coverage_pct attribute. */
                require constraint {
                    spacecraft.mission_coverage_pct >= 99.0
                }
            }

            requirement <'L2-REQ-015'> simulationTermination {
                doc /* Terminate simulation at 100% global coverage.
                     * Triggers use case 'Acquire And Deliver Observation Data' done. */
            }

            // ── Environment Classification ─────────────────────────────
            // Physical owner: GNCSubsystem > ACSSubsystem 
            // ACS classifies; sends Apply_Rate_Profile(Tag) to CDH
            // Use case: 'Perform Environmental Classification'

            requirement <'L2-REQ-020'> dayNightClassification {
                doc /* Classify swath as Day/Night using SPICE solar elevation > 0.
                     * Satisfied by GNCSubsystem > ACSSubsystem.classifyEnvironment
                     *   → acs_isDayFlag; input: EarthEnvironment.solarElevation_deg.
                     * ACS sends classification tag to CDH for data rate selection. */
            }

            requirement <'L2-REQ-021'> landOceanClassification {
                doc /* Classify swath as Land/Ocean using global-land-mask.
                     * Satisfied by GNCSubsystem > ACSSubsystem.classifyEnvironment
                     *   → acs_isLandFlag. */
            }

            requirement <'L2-REQ-022'> landPriorityOverride {
                doc /* Land overrides Ocean when footprint overlaps both.
                     * Satisfied by ACSSubsystem.classifyEnvironment priority logic
                     *   (acs_landPriority = true). */
            }

            requirement <'L2-REQ-023'> dayPriorityOverride {
                doc /* Day overrides Night when footprint overlaps both.
                     * Satisfied by ACSSubsystem.classifyEnvironment priority logic. */
            }

            // ── Instrument Data Generation ─────────────────────────────
            // Physical owner: AvionicsSubsystem > OBC/CDH > MissionSoftware
            //  OBC runs CDH software; Science Instrument provides data stream

            requirement <'L2-REQ-030'> continuousDataGeneration {
                doc /* Generate science data continuously in nadir mode.
                     * Satisfied by CDH generateAndStoreData; Science Instrument
                     *   provides continuous data stream to Avionics (OBC/CDH). */
            }

            requirement <'L2-REQ-031'> dataRateProfiles {
                doc /* Data rate depends on environment classification:
                     * LAND_DAY=100 Mbps, LAND_NIGHT=50 Mbps, OCEAN=10 Mbps.
                     * Satisfied by: CDH selectDataRate reading cdh_envClass. */
            }

            requirement <'L2-REQ-032'> dataRateApplication {
                doc /* Apply correct rate per resolved classification rule.
                     * Satisfied by: CDH selectDataRate → cdh_dataRateMbps. */
            }

            requirement <'L2-REQ-033'> totalDataVolume {
                doc /* Compute and record total science data volume over time.
                     * Satisfied by: CDH cdh_totalGenerated_gb accumulator. */
            }

            // ── Onboard Storage ────────────────────────────────────────
            // Physical owner: AvionicsSubsystem > DataStorage
            // Use case: 'Manage Onboard Storage Overflow'

            requirement <'L2-REQ-040'> recorderCapacity {
                doc /* Model onboard recorder with configurable capacity (baseline 100 GB).
                     * Satisfied by: AvionicsSubsystem > DataStorage;
                     *   attribute: cdh_recorderCap_gb. */
                subject cdh :> spacecraft.cdh;
                require constraint {
                    cdh.cdh_recorderFill_gb <= cdh.cdh_recorderCap_gb
                }
            }

            requirement <'L2-REQ-041'> dataRetentionPolicy {
                doc /* Store data until downlinked or removed by overflow policy.
                     * Satisfied by: CDH generateAndStoreData → DataStorage. */
            }

            requirement <'L2-REQ-042'> recorderOccupancyTracking {
                doc /* Track recorder occupancy and report time histories.
                     * Satisfied by CDH cdh_recorderFill_gb time history.
                     * Recorder_Occupancy_Status message: CDH → TT&C → Ground. */
            }

            requirement <'L2-REQ-043'> overflowPolicy {
                doc /* Enforce drop-newest/drop-oldest/drop-lowest-priority
                     * when capacity exceeded.
                     * Satisfied by: CDH enforceOverflowPolicy action
                     *   (use case 'Manage Onboard Storage Overflow'). */
            }

            requirement <'L2-REQ-044'> dataLossLogging {
                doc /* Log data loss events from overflow.
                     * Satisfied by: cdh_dataLoss_gb accumulator. */
            }

            // ── Ground Contacts & Downlink ─────────────────────────────
            // Physical owner: CommunicationsSubsystem > TT&C 
            //  TT&C owns complete uplink/downlink chain:
            //   Uplink:   Ground → TT&C → OBC.parseAndDispatch → GNC(ACS)
            //   Downlink: CDH → TT&C → Ground (Science_Data_Packet)
            //   Health:   CDH → TT&C → Ground (Recorder_Occupancy_Status)
            // Use case: 'Downlink Data To Ground Station'

            requirement <'L2-REQ-050'> groundContactPrediction {
                doc /* Predict contact opportunities for each of the 9 stations.
                     * Satisfied by MissionTTCSubsystem.evaluateLineOfSight
                     *   → acs_gsElevation_deg > 10° (elevationMask_deg).
                     * Physical: CommunicationsSubsystem gndcmdAndDataif port. */
                subject gs :> spacecraft.ttc;
                require constraint {
                    spacecraft.gnc.acs.acs_gsElevation_deg > 10.0
                }
            }

            requirement <'L2-REQ-051'> downlinkSessionModelling {
                doc /* Model downlink sessions during contact windows.
                     * Satisfied by TT&C openRFLink → transmitData sequence. */
            }

            requirement <'L2-REQ-052'> downlinkThroughput {
                doc /* Downlink at 250 Mbps subject to contact duration.
                     * Satisfied by CommunicationsSubsystem > HighRateAntenna
                     *   + HRXmitAmplifier; TT&C transmitData (Science_Data_Packet).
                     *   Attribute: tel_downlinkMbps = 250. */
            }

            requirement <'L2-REQ-053'> recorderVolumeReduction {
                doc /* Reduce recorder occupancy by downlinked volume.
                     * Satisfied by TT&C confirmDownlink → CDH updates
                     *   cdh_recorderFill_gb - tel_dataDownlinked_gb. */
            }

            requirement <'L2-REQ-054'> downlinkFailureHandling {
                doc /* Retain undelivered data and reschedule on next contact.
                     * Satisfied by TT&C closeRFLink without data loss flag. */
            }

            // ── Propagation, Execution Control & Reporting ─────────────

            requirement <'L2-REQ-060'> spacecraftPropagation {
                doc /* Propagate spacecraft position and time for run duration.
                     * Satisfied by GNCSubsystem orbital propagation
                     *   via GPS + IMU. GNC owns propagation per decomposition
                     *   (L2-REQ-060 allocated to GNC alongside coverage math). */
            }

            requirement <'L2-REQ-061'> configurableTimeStep {
                doc /* Support configurable simulation time step.
                     * Satisfied by: CDH updateCoverageGrid step parameter. */
            }

            requirement <'L2-REQ-062'> initializationCheck {
                doc /* Detect and report failure to initialize scenario elements.
                     * Satisfied by: establishOrbit action → eps_orbitEstablished. */
            }

            requirement <'L2-REQ-063'> maxSimulationDuration {
                doc /* Support configurable maximum run duration or orbit count.
                     * Satisfied by: mission_missionDurH upper bound. */
            }

            requirement <'L2-REQ-064'> maxRunTermination {
                doc /* Terminate and report if max run reached before 100% coverage.
                     * Triggers: use case terminate path on mission_missionDurH exceeded. */
            }

            requirement <'L2-REQ-065'> summaryOutputs {
                doc /* Generate: time-to-coverage, coverage%, peak recorder occupancy,
                     * total downlinked volume, per-station utilization.
                     * Satisfied by: MissionSpacecraft summary attributes. */
            }

            // ── Demo 2 Requirements ────────────────────────────────────
            // Physical owner: GNCSubsystem > ACSSubsystem ( ACS nested)
            //                 AvionicsSubsystem > OBC/CDH > MissionSoftware
            //                 PowerSubsystem (Battery load notification)
            //                 CommunicationsSubsystem > TT&C (command uplink)
            // Use case: 'Perform Target Observation Manoeuvre' (4-phase)

            requirement <'DEMO2-REQ-001'> targetDetection {
                doc /* Detect designated ground target in spacecraft FOV.
                     * Satisfied by GNCSubsystem > ACSSubsystem.detectTargetInView
                     *   → acs_targetInView; physical: GPSUnit + StarTracker
                     *   via GNCSW ports p6, p7. Triggered after OBC.parseAndDispatch
                     *   receives Execute_Slew command from TT&C uplink (Phase 1). */
            }


            requirement <'DEMO2-REQ-002'> torqueComputation {
                doc /* Compute reaction-wheel torque for nadir→target slew.
                     * Satisfied by GNCSubsystem > ACSSubsystem.computeTorque
                     *   → Compute_Control_Torque; physical: ReactionWheel[4] torque_if.
                     * Phase 2 (Execution) of Demo 2 4-phase flow. */
            }

            requirement <'DEMO2-REQ-003'> slewManoeuvre {
                doc /* Execute slew from NADIR_ACQUISITION to TARGET_TRACKING.
                     * Satisfied by GNCSubsystem > ACSSubsystem.slewToTarget
                     *   → acs_mode = TARGET_TRACKING.
                     * SM: NADIR_ACQUISITION → MANOEUVRING → TARGET_TRACKING. */
            }

            requirement <'DEMO2-REQ-004'> highRateObservation {
                doc /* Activate CDH HIGH_RATE mode when ACS confirms target pointing.
                     * GNC(ACS) sends classification tag to CDH;
                     *   MissionCDHSubsystem.activateObservation → cdh_mode = HIGH_RATE.
                     * Physical: AvionicsSubsystem > OBC/CDH > MissionSoftware.
                     * Phase 3 (Observation) of Demo 2 4-phase flow. */
            }

            requirement <'DEMO2-REQ-005'> maneuverPowerNotification {
                doc /* ACS notifies EPS of manoeuvre power load increase.
                     * Satisfied by MissionEPSSubsystem.notifyManeuverLoad
                     *   → Report_Maneuver_Power message → eps_maneuverPower_w set.
                     * Interface: GNCSubsystem.pwr_if → PowerSubsystem.cmdtlm.
                     * Phase 2 (Execution) of Demo 2 4-phase flow. */
            }
            

            requirement <'DEMO2-REQ-006'> returnToNadir {
                doc /* Return to nadir after target observation.
                     * Satisfied by GNCSubsystem > ACSSubsystem.slewToNadir
                     *   → acs_mode = NADIR.
                     * SM: TARGET_TRACKING → NADIR_ACQUISITION.
                     * Followed by Phase 4 (Reporting): TT&C downlinks
                     * Science_Data_Packet + Recorder_Occupancy_Status. */
            }
        }
    }

    // =========================================================================
    // 2-Structure — Mission Types + Spacecraft black-box part def
    // Shared scalar types, enumerations, and the external interface of the SoI.
    // SpacecraftPhysical in 'Physical Architecture' specialises Spacecraft here.
    // =========================================================================
    package '2-Structure' {

        package 'Mission Types' {

            // Enumerations
            enum def ACSMode {
                NADIR;           // nadir-pointing acquisition (Demo 1 nominal)
                TARGET_TRACKING; // pointing to a ground target (Demo 2)
                SAFE_HOLD;       // safe mode
            }

            enum def CDHMode {
                IDLE;
                ACQUISITION;
                HIGH_RATE; // activated by DEMO2-REQ-004
                DOWNLINK;
            }

            enum def EnvironmentClass {
                LAND_DAY;   // 100 Mbps data rate
                LAND_NIGHT; // 50 Mbps
                OCEAN;      // 10 Mbps
            }

            // Typed scalar attributes (SI-unit–tagged reals)
            attribute def RealKm   :> ScalarValues::Real; // kilometres
            attribute def RealDeg  :> ScalarValues::Real; // degrees
            attribute def RealGB   :> ScalarValues::Real; // gigabytes
            attribute def RealMbps :> ScalarValues::Real; // megabits/s
            attribute def RealNm   :> ScalarValues::Real; // newton-metres
            attribute def RealPct  :> ScalarValues::Real; // percent
            attribute def RealH    :> ScalarValues::Real; // hours
            attribute def RealW    :> ScalarValues::Real; // watts
        }

        // ── Spacecraft (SoI) ────────────────────────────────────
        // Defines the external interface of the SoI: physical properties and
        // all 16 external interface ports mapping to physical subsystem IBDs.
        // SpacecraftPhysical in 'Physical Architecture' > '2-Structure'
        // specialises this part def.
        part def Spacecraft {
            // Physical properties (mass budget, sizing, etc.)
            attribute Mass;
            attribute Size;
            attribute Power;
            attribute DeltaV;
            attribute 'Max radiation level';
            attribute Reliability;
            attribute Life;
            attribute Cost;
            attribute 'Data capacity';
            attribute 'Probability of detection';
            attribute 'Probability of false alarm';
            attribute 'Pointing Accuracy';
            // FIX 10-S1: was bare 'Orbit;' — now proper attribute
            attribute Orbit;

            // External interface ports
            // (each maps to a physical subsystem interface in '4-Subsystems')
            port 'solar radiation i/f';      // → PowerSubsystem.solar_if (SolarArray)
            port 'em radiation i/f';         // → ThermalSubsystem.radiationIF
            port 'observation sensor i/f';   // → PayloadSubsystem.'observation sensor if'
            port 'thrust i/f';               // → PropulsionSubsystem.thrust_if
            port 'gnd cmd & data i/f';       // → CommunicationsSubsystem.gndcmdAndDataif + GndCmdAndTlmif
            port 'LV electrical i/f';        // → PowerSubsystem.ivpowerif (launch vehicle power)
            port 'LV mechanical i/f';        // → StructureSubsystem.lvMechPort
            port 'thermal radiation i/f';    // → ThermalSubsystem.radiationIF
            port 'star tracker i/f';         // → GNCSubsystem: StarTracker.star_tracker_if
            port 'inertial sensor i/f';      // → GNCSubsystem: IMU.inertial_ref_if
            port 'impact i/f';               // → StructureSubsystem.impactPort
            port 'gps i/f';                  // → GNCSubsystem: GPSUnit.gps_if
            port 'horizon tracker i/f';      // → GNCSubsystem: HorizonTracker
            port 'drag i/f';                 // → StructureSubsystem.dragPort
            port 'sun tracker i/f';          // → GNCSubsystem: SunTracker
            port 'magnetometer i/f';         // → GNCSubsystem: Magnetometer
        }
    }

    // =========================================================================
    // 3-Use Cases
    // Use case defs reference mission part defs from '6-Spacecraft' >
    // 'Physical Architecture' > '4-Subsystems' > 'Mission Subsystems'.
    // The perform steps are deliberately named to match the action names
    // defined in SpacecraftPhysical's 'Collect And Downlink Observation Data'
    // action block — establishing the use-case-to-action binding (mechanism 3).
    // =========================================================================
    package '3-Use Cases' {
        public import 'Spacecraft Mission — Integrated'::'2-Structure'::'Mission Types'::*;
        public import 'Spacecraft Mission — Integrated'::'6-Spacecraft'::'Physical Architecture'::'4-Subsystems'::'Mission Subsystems'::*;

        // ── Message payload types used by use-case message flows ─────────────
        item def MissionUpload;    // ground-operator → spacecraft uplink command
        item def ScienceData;      // science instrument → spacecraft onboard storage
        item def SolarVector;      // earth environment → GNC/ACS day/night input
        item def LandMask;         // earth environment → GNC/ACS land/ocean input
        item def DownlinkStream;   // spacecraft → ground station RF downlink
        item def ContactAck;       // ground station → spacecraft contact acknowledgement

        // ── Demo 1 — Primary Use Case ─────────────────────────────────────────
        // Binds to: SpacecraftPhysical perform action 'Collect and Downlink
        // Observation Data' (full pipeline). Terminates at L2-REQ-015 (100% coverage).
        //  gnc.acs.classifyEnvironment; ttc.* replaces comms.*
use case def 'Acquire And Deliver Observation Data' {
    doc
    /* Demo 1 primary use case.
     * Nadir-only continuous science data acquisition at 750 km SSO.
     * GNC (ACS) holds nadir [L2-REQ-002]; Science Instrument always on [L2-REQ-003].
     * ACS classifies environment; CDH applies data-rate profile [L2-REQ-031].
     * Data stored in OBC DataStorage [L2-REQ-040]; downlinked via TT&C to
     * 9-station network [L2-REQ-050-054]. Terminates at >99% coverage [L2-REQ-015]. */

    subject spacecraft : MissionSpacecraft {
        event occurrence orbitEstablished     [1];
        then event occurrence missionActivated    [1];
        then event occurrence nadirModeSet        [1];
        then event occurrence environmentClassified [1..*];
        then event occurrence dataRateSelected    [1..*];
        then event occurrence dataStoredOnboard   [1..*];
        then event occurrence losEvaluated        [1..*];
        then event occurrence rfLinkOpened        [1..*];
        then event occurrence dataTransmitted     [1..*];
        then event occurrence downlinkConfirmed   [1..*];
    }

    actor groundOperator : GroundOperator {
        event occurrence uploadsMission   [1];
        event occurrence receivesStatus   [0..*];
    }

    actor groundNetwork : GroundStationNetwork {
        event occurrence acknowledgesContact [0..*];
        event occurrence receivesData        [0..*];
    }

    actor earthEnv : EarthEnvironment {
        event occurrence providesSolarVector [1..*];
        event occurrence providesLandMask    [1..*];
    }

    actor scienceInstrument : ScienceInstrument {
        event occurrence providesScienceData [1..*];
    }

    objective {
        doc
        /* Achieve >99% global surface coverage within 72 h [L2-REQ-014].
         * GNC(ACS) classifies every swath interval: Day/Night x Land/Ocean [L2-REQ-020-023].
         * CDH/OBC enforces onboard storage integrity [L2-REQ-040-044].
         * TT&C downlinks all acquired data to 9-station network [L2-REQ-050-054]. */
    }

    // Message flows — TT&C owns uplink/downlink chain
    message missionUpload   from groundOperator.uploadsMission        to spacecraft.missionActivated;
    message scienceData     from scienceInstrument.providesScienceData to spacecraft.dataStoredOnboard;
    message solarVector     from earthEnv.providesSolarVector          to spacecraft.environmentClassified;
    message landMask        from earthEnv.providesLandMask             to spacecraft.environmentClassified;
    message downlinkStream  from spacecraft.dataTransmitted            to groundNetwork.receivesData;
    message contactAck      from groundNetwork.acknowledgesContact      to spacecraft.losEvaluated;

    // Execution sequence
    first start;
        then perform spacecraft.establishOrbit;              // eps_orbitEstablished [L2-REQ-062]
        then perform spacecraft.activateMissionMode;         // cdh_mode = ACQUISITION
        then perform spacecraft.gnc.acs.setNadirMode;        // acs_mode = NADIR [L2-REQ-002]
        then perform spacecraft.gnc.acs.classifyEnvironment; // Day/Night x Land/Ocean [L2-REQ-020-023]
        then perform spacecraft.cdh.selectDataRate;          // cdh_dataRateMbps from ACS tag [L2-REQ-031]
        then perform spacecraft.cdh.generateAndStoreData;    // Store Data in OBC [L2-REQ-030,040]
        then perform spacecraft.ttc.evaluateLineOfSight;     // contact window [L2-REQ-050]
        then perform spacecraft.ttc.openRFLink;              // TT&C RF link open [L2-REQ-051]
        then perform spacecraft.ttc.transmitData;            // Science_Data_Packet [L2-REQ-052]
        then perform spacecraft.ttc.confirmDownlink;         // Recorder_Occupancy_Status [L2-REQ-053]
        then done;
}

        // ── Supporting Use Case 1: Environmental Classification ───────────────
        //  ACS nested within GNC; subject is GNC, actions via gnc.acs.*
        // Satisfies: L2-REQ-020, 021, 022, 023
        use case def 'Perform Environmental Classification' {
            doc /* GNC(ACS) classifies each swath interval using SPICE solar geometry
                 * (Day/Night) and global-land-mask (Land/Ocean).
                 * ACS sends classification tag to CDH to trigger data rate selection.
                 * Applies Land Priority [L2-REQ-022] and Day Priority [L2-REQ-023]. */

            subject gnc    : MissionGNCSubsystem {   //  ACS nested within GNC
                event occurrence swathComputed          [1..*];
                then event occurrence environmentClassified [1..*];
            }
            actor earthEnv : EarthEnvironment {
                event occurrence providesSolarVector [1..*];
                event occurrence providesLandMask    [1..*];
            }

            objective {
                doc /* Resolve Day/Night × Land/Ocean classification per swath step.
                     * [L2-REQ-020, L2-REQ-021, L2-REQ-022, L2-REQ-023]
                     * ACS sends Apply_Rate_Profile(Tag) to CDH. */
            }

            // solarVector → EarthEnvironment.solarElevation_deg → acs_isDayFlag
            // landMask    → global-land-mask → acs_isLandFlag
            message solarVector from earthEnv.providesSolarVector to gnc.swathComputed;
            message landMask    from earthEnv.providesLandMask    to gnc.environmentClassified;

            first start;
                then perform gnc.acs.computeSwath;          // → acs_swathKm [L2-REQ-010]
                then perform gnc.acs.classifyEnvironment;   // → cdh_envClass tag sent to CDH [L2-REQ-020-023]
                then done;
        }

        // ── Supporting Use Case 2: Onboard Storage Overflow ──────────────────
        // Drives: CDH enforceOverflowPolicy action inside 'Store Data'
        // Satisfies: L2-REQ-043, L2-REQ-044
        use case def 'Manage Onboard Storage Overflow' {
            doc /* CDH enforces configurable overflow policy when
                 * cdh_recorderFill_gb would exceed cdh_recorderCap_gb. */

            subject cdh : MissionCDHSubsystem {   // CDH function in AvionicsSubsystem
                event occurrence overflowDetected [0..*];
                then event occurrence policyEnforced  [0..*];
            }

            objective {
                doc /* Enforce drop-newest or drop-oldest policy [L2-REQ-043].
                     * Log data loss events to cdh_dataLoss_gb [L2-REQ-044]. */
            }

            first start;
                then perform cdh.enforceOverflowPolicy;  // triggers on recorder full
                then done;
        }

        // ── Supporting Use Case 3: Downlink to Ground Station ────────────────
        //  subject is MissionTTCSubsystem (renamed from MissionCommsSubsystem).
        // TT&C owns the complete uplink/downlink chain. Satisfies: L2-REQ-050-054.
        use case def 'Downlink Data To Ground Station' {
            doc /* TT&C subsystem manages RF link and data offloading during ground
                 * station contact windows.
                 * TT&C is the primary owner of L2-REQ-050-054.
                 * Downlink chain: CDH → TT&C → Ground (Science_Data_Packet).
                 * Health TLM chain: CDH → TT&C → Ground (Recorder_Occupancy_Status). */

            subject ttc         : MissionTTCSubsystem {   //  TT&C owns RF chain
                event occurrence losEvaluated       [1..*];
                then event occurrence rfLinkOpened      [1..*];
                then event occurrence dataTransmitted   [1..*];
                then event occurrence downlinkConfirmed [1..*];
                then event occurrence healthTlmSent     [1..*];
                then event occurrence rfLinkClosed      [1..*];
            }
            actor groundNetwork : GroundStationNetwork {  // → '7-Ground Station'
                event occurrence acknowledgesContact [0..*];
                event occurrence receivesData        [0..*];
                event occurrence receivesHealthTlm   [0..*];
            }

            objective {
                doc /* Predict contact windows [L2-REQ-050, L2-REQ-051].
                     * Downlink Science_Data_Packet at 250 Mbps via HighRateAntenna [L2-REQ-052].
                     * Transmit Recorder_Occupancy_Status health TLM [L2-REQ-042].
                     * Update CDH recorder occupancy [L2-REQ-053].
                     * Retain data on link failure [L2-REQ-054]. */
            }

            // contactAck  → gndcmdAndDataif (CommunicationsSubsystem)
            // dataStream  → observationdata_if (Science_Data_Packet)
            // healthTlm   → Recorder_Occupancy_Status
            message contactAck from groundNetwork.acknowledgesContact to ttc.losEvaluated;
            message dataStream from ttc.dataTransmitted               to groundNetwork.receivesData;
            message healthTlm  from ttc.healthTlmSent                 to groundNetwork.receivesHealthTlm;

            first start;
                then perform ttc.evaluateLineOfSight;    // → tel_inContact; acs_gsElevation_deg > 10° [L2-REQ-050]
                then perform ttc.openRFLink;             // → RF link activated [L2-REQ-051]
                then perform ttc.transmitData;           // → Science_Data_Packet 250 Mbps [L2-REQ-052]
                then perform ttc.confirmDownlink;        // → CDH fill reduced; Recorder_Occupancy_Status [L2-REQ-053]
                then perform ttc.transmitHealthTelemetry;// → Recorder_Occupancy_Status to Ground [L2-REQ-042]
                then perform ttc.closeRFLink;            // → RF link deactivated [L2-REQ-054]
                then done;
        }

        // ── Supporting Use Case 4: Safe Mode Recovery ─────────────────────────
        // Drives: EPS monitorSoCRecovery, spacecraft returns to IDLE state
        // Satisfies: EPS TBD requirements
        use case def 'Execute Safe Mode Recovery' {
            doc /* Mission enters safe mode when eps_socPercent_pct < 15%.
                 * EPS monitors SoC and returns spacecraft to IDLE at >= 30%.
                 * Full EPS model TBD. */

            subject spacecraft   : MissionSpacecraft {
                event occurrence safeModeEntered [1];
                then event occurrence socRecovered   [1];
            }
            actor groundOperator : GroundOperator {   // → '9-Launch Operations Facility'
                event occurrence receivesAlert [0..*];
            }

            objective {
                doc /* Minimise power consumption in SAFE_HOLD ACS mode.
                     * Monitor SoC via PowerMgmtSW → Battery telemetry.
                     * Return to IDLE state when SoC recovers. */
            }

            // safeAlert → 'gnd cmd & data i/f' (telemetry uplink)
            message safeAlert from spacecraft.safeModeEntered to groundOperator.receivesAlert;

            first start;
                then perform spacecraft.eps.monitorSoCRecovery;
                then done;
        }

        // ── Demo 2 — Target Observation Manoeuvre ─────────────────────────────
        //  4-phase interaction flow formalised:
        //   Phase 1 — Command    : Ground → TT&C → OBC.parseAndDispatch → GNC(ACS)
        //   Phase 2 — Execution  : GNC calculates; ACS computes torque; GNC → EPS
        //   Phase 3 — Observation: GNC(ACS) → CDH HIGH_RATE; Science data stored
        //   Phase 4 — Reporting  : CDH → TT&C → Ground (Science_Data_Packet +
        //                          Recorder_Occupancy_Status)
        // State Machine states: IDLE → NADIR_ACQUISITION → MANOEUVRING →
        //             TARGET_TRACKING → NADIR_ACQUISITION
        // Satisfies: DEMO2-REQ-001 through DEMO2-REQ-006
        use case def 'Perform Target Observation Manoeuvre' {
            doc /* Demo 2 use case — 4-phase interaction flow.
                 * Phase 1 (Command): Ground Station sends Execute_Slew(Target_X)
                 *   uplink to TT&C; OBC parses and dispatches manoeuvre trigger
                 *   to GNC (ACS) [DEMO2 Target Command].
                 * Phase 2 (Execution): GNC calculates target vector; ACS computes
                 *   Compute_Control_Torque via ReactionWheel[4] [DEMO2-REQ-002];
                 *   GNC notifies EPS of Report_Maneuver_Power load [DEMO2-REQ-005].
                 * Phase 3 (Observation): GNC(ACS) confirms pointing achieved and
                 *   sends classification tag to CDH; CDH activates HIGH_RATE mode
                 *   [DEMO2-REQ-004]; Science Instrument data stream stored in OBC.
                 * Phase 4 (Reporting): CDH packages Observation_Successful telemetry;
                 *   TT&C downlinks Science_Data_Packet + Recorder_Occupancy_Status
                 *   to Ground Station [L2-REQ-042, L2-REQ-052]. */

            subject spacecraft   : MissionSpacecraft {
                // Phase 1 — Command
                event occurrence uplinkReceived         [1];
                then event occurrence commandDispatched     [1];
                // Phase 2 — Execution
                then event occurrence targetDetected        [1];
                then event occurrence torqueComputed        [1];
                then event occurrence slewingToTarget       [1];
                then event occurrence maneuverLoadReported  [1];
                // Phase 3 — Observation
                then event occurrence observationActive     [1];
                // Phase 4 — Reporting
                then event occurrence slewingToNadir        [1];
                then event occurrence dataTransmitted       [1];
                then event occurrence healthTlmSent         [1];
            }
            actor groundTarget   : GroundTarget {     // provides Uplink_Target_Coords
                event occurrence providesTargetCoordinates [1];
            }
            actor groundOperator : GroundOperator {   // sends Execute_Slew command
                event occurrence sendsExecuteSlew [1];
                event occurrence receivesAlert    [0..*];
                event occurrence receivesReport   [0..*];
            }

            objective {
                doc /* Execute full nadir→target→nadir slew cycle with
                     * high-rate observation, EPS load notification,
                     * and health telemetry reporting. */
            }

            // Phase 1 — Command messages
            // targetUplink   → Ground → TT&C uplink (Execute_Slew(Target_X))
            // manoeuvreAlert → spacecraft → groundOperator (status notification)
            message targetUplink      from groundOperator.sendsExecuteSlew          to spacecraft.uplinkReceived;
            message targetCoordinates from groundTarget.providesTargetCoordinates   to spacecraft.commandDispatched;
            message manoeuvreAlert    from spacecraft.maneuverLoadReported           to groundOperator.receivesAlert;
            // Phase 4 — Reporting messages
            message observationReport [*] from spacecraft.dataTransmitted           to groundOperator.receivesReport;
 
            // Corrected + extended sequence :
            // Phase 1 — Command
            first start;
            // Phase 1 — Command
                then perform spacecraft.ttc.receiveUplink;        // Execute_Slew(Target_X) received [DEMO2-Target]
                then perform spacecraft.cdh.parseAndDispatch;     // OBC parses; dispatches to GNC(ACS) [DEMO2]
            // Phase 2 — Execution
                then perform spacecraft.gnc.acs.detectTargetInView;  // acs_targetInView [DEMO2-REQ-001]
                then perform spacecraft.gnc.acs.computeTorque;        // Compute_Control_Torque via RW[4] [DEMO2-REQ-002]
                then perform spacecraft.gnc.acs.slewToTarget;         // acs_mode = TARGET_TRACKING [DEMO2-REQ-003]
                then perform spacecraft.eps.notifyManeuverLoad;       // Report_Maneuver_Power to EPS [DEMO2-REQ-005]
            // Phase 3 — Observation
                then perform spacecraft.cdh.activateObservation;      // CDH HIGH_RATE; ACS tag [DEMO2-REQ-004]
            // Phase 4 — Reporting + return to nadir
                then perform spacecraft.gnc.acs.slewToNadir;          // acs_mode = NADIR [DEMO2-REQ-006]
                then perform spacecraft.ttc.transmitData;             // Science_Data_Packet downlink [L2-REQ-052]
                then perform spacecraft.ttc.transmitHealthTelemetry;  // Recorder_Occupancy_Status [L2-REQ-042]
                then done;
        }
    }

    // =========================================================================
    // 4-Behavior — SDA State Machine + Action Pipelines
    // =========================================================================
    // State machine: 6 states (SAFE merges SAFE + SAFE_RECOVERY from earlier
    //   stub — both serve the same low-power holding purpose):
    //   SAFE, IDLE, NADIR_ACQUISITION, MANOEUVRING,
    //   TARGET_TRACKING, DOWNLINK
    //
    // Action pipelines:
    //   DataAcquisitionPipeline  — 5-step sequential flow (NADIR_ACQUISITION)
    //   Demo2ManoeuvreSequence   — 4-step slew pipeline (MANOEUVRING / TARGET_TRACKING)
    // =========================================================================
    package '4-Behavior' {

        // ── Imports — types from top-level '2-Structure' > 'Mission Types' ──
        public import 'Spacecraft Mission — Integrated'::'2-Structure'::'Mission Types'::*;

        // =====================================================================
        // SDA State Machine
        // =====================================================================
        package 'SDA State Machine' {

            state def SpacecraftMissionSM {
                doc /* Mission mode state machine for the SDA spacecraft.
                     * Demo 1 states: SAFE, IDLE, NADIR_ACQUISITION, DOWNLINK.
                     * Demo 2 additional: MANOEUVRING, TARGET_TRACKING.
                     * SAFE merges SAFE + SAFE_RECOVERY (same low-power purpose).
                     * Guard attributes are bound to mission subsystem attributes
                     * via redefines in MissionSpacecraft. */

                // ── Guard attributes ────────────────────────────────────────
                // Mapped from MissionSpacecraft / subsystem attributes
                attribute socPercent       : RealPct;  // eps_socPercent_pct
                attribute gsElevationDeg   : RealDeg;  // acs_gsElevation_deg
                attribute recorderGB       : RealGB;   // cdh_recorderFill_gb
                attribute coveragePercent  : RealPct;  // mission_coverage_pct
                attribute orbitEstablished : ScalarValues::Boolean; // eps_orbitEstablished

                // Demo 2 guard attributes
                attribute targetInView     : ScalarValues::Boolean; // acs_targetInView
                attribute pointingAchieved : ScalarValues::Boolean; // acs_pointingAchieved
                attribute observationDone  : ScalarValues::Boolean; // CDH completion flag

                // ── STATES ──────────────────────────────────────────────────

                state SAFE {
                    doc /* Merged SAFE + SAFE_RECOVERY state.
                         * Handles both initial boot and low-SoC recovery
                         * (same low-power holding purpose — no distinct behaviour).
                         * Entry: system boot OR socPercent < 15%.
                         * Exit:  socPercent >= 30% AND orbitEstablished.
                         * Maps to: L2-REQ-001, L2-REQ-062 */
                    entry action initMinimalPower {
                        doc /* ACS: SAFE_HOLD attitude.
                             * EPS: minimal power draw; payload off. */
                    }
                    do action monitorSoC {
                        doc /* EPS: poll socPercent every 60 s.
                             * Await socPercent >= 30% to exit. */
                    }
                }

                state IDLE {
                    doc /* Orbital coasting. Attitude maintained. No imaging.
                         * Entry: orbit established AND socPercent >= 30%.
                         * Maps to: L2-REQ-001-004 */
                    entry action stabilizeOrbit {
                        doc /* Verify propagated orbital state [L2-REQ-060]. */
                    }
                    do action scanHorizon {
                        doc /* Evaluate next ground station contact window
                             * [L2-REQ-050]. */
                    }
                }

                state NADIR_ACQUISITION {
                    doc /* Active nadir-pointing imaging. CDH records at rate
                         * determined by environment class [L2-REQ-031].
                         * ACS: z-axis nadir [L2-REQ-002].
                         * Maps to: L2-REQ-002, L2-REQ-030-044 */
                    entry action activatePayload {
                        doc /* Power Science Instrument; set integration time
                             * [L2-REQ-003]. */
                    }
                    do action runDataPipeline {
                        doc /* Execute DataAcquisitionPipeline
                             * (see 'SDA Actions' package). */
                    }
                    exit action deactivatePayload {
                        doc /* Safe Science Instrument before mode transition. */
                    }
                }

                state MANOEUVRING {
                    doc /* Demo 2: ACS computing torque; reaction wheels
                         * accelerating toward target attitude.
                         * Power spike notified to EPS [DEMO2-REQ-005].
                         * Entry: targetInView == true. */
                    entry action computeTorqueEntry {
                        doc /* ACS -> EPS: Report_Maneuver_Power
                             * [DEMO2-REQ-002, DEMO2-REQ-005]. */
                    }
                    do action executeSlewToTarget {
                        doc /* ACS slews spacecraft to target attitude.
                             * Reaction wheels actuate [DEMO2-REQ-003]. */
                    }
                }

                state TARGET_TRACKING {
                    doc /* Demo 2: spacecraft slewed to target.
                         * CDH in HIGH_RATE observation mode.
                         * Entry: pointingAchieved == true.
                         * Maps to: DEMO2-REQ-003, DEMO2-REQ-004 */
                    entry action notifyCDHObservationActive {
                        doc /* GNC(ACS) -> CDH: Observation_Active
                             * [DEMO2-REQ-004]. */
                    }
                    do action runHighRateObservation {
                        doc /* CDH: generate data at HIGH_RATE.
                             * Science Instrument provides data stream. */
                    }
                    exit action slewToNadirOnComplete {
                        doc /* ACS: return to nadir [DEMO2-REQ-006]. */
                    }
                }

                state DOWNLINK {
                    doc /* Ground station in LoS (elevation > 10°).
                         * TT&C active; CDH draining recorder at 250 Mbps.
                         * Maps to: L2-REQ-050-054 */
                    entry action openCommLink {
                        doc /* TT&C: Contact_Alert received [L2-REQ-050].
                             * Configure RF chain (HighRateAntenna). */
                    }
                    do action drainRecorder {
                        doc /* CDH -> TT&C: Science_Data_Packet
                             *   at 250 Mbps [L2-REQ-052].
                             * TT&C -> CDH: Update_Recorder(-Vol)
                             *   [L2-REQ-053]. */
                    }
                    exit action closeCommLink {
                        doc /* RF chain safing on end of contact window
                             * [L2-REQ-054]. */
                    }
                }

                // ── TRANSITIONS ─────────────────────────────────────────────

                // Entry point
                entry;
                then SAFE;

                // Boot → operational
                transition safeToIdle
                    first SAFE
                    if orbitEstablished & socPercent >= 30.0
                    then IDLE;

                // Acquisition entry from IDLE
                transition idleToAcquisition
                    first IDLE
                    if socPercent >= 30.0 & gsElevationDeg < 10.0
                    then NADIR_ACQUISITION;

                // Downlink takes priority over acquisition from IDLE
                transition idleToDownlink
                    first IDLE
                    if gsElevationDeg >= 10.0 & recorderGB > 0.0
                    then DOWNLINK;

                // Demo 2: target detected — begin slew
                transition acquisitionToManoeuvring
                    first NADIR_ACQUISITION
                    if targetInView
                    then MANOEUVRING;

                // Demo 2: slew complete — begin high-rate observation
                transition manoeuvringToTracking
                    first MANOEUVRING
                    if pointingAchieved
                    then TARGET_TRACKING;

                // Demo 2: observation complete — return to nadir acquisition
                transition trackingToAcquisition
                    first TARGET_TRACKING
                    if observationDone
                    then NADIR_ACQUISITION;

                // GS contact interrupts acquisition or Demo 2 states
                transition acquisitionToDownlink
                    first NADIR_ACQUISITION
                    if gsElevationDeg >= 10.0
                    then DOWNLINK;

                transition manoeuvringToDownlink
                    first MANOEUVRING
                    if gsElevationDeg >= 10.0
                    then DOWNLINK;

                transition trackingToDownlink
                    first TARGET_TRACKING
                    if gsElevationDeg >= 10.0
                    then DOWNLINK;

                // Post-downlink routing
                transition downlinkToAcquisition
                    first DOWNLINK
                    if gsElevationDeg < 10.0 & coveragePercent < 99.0
                    then NADIR_ACQUISITION;

                transition downlinkToIdle
                    first DOWNLINK
                    if gsElevationDeg < 10.0 & coveragePercent >= 99.0
                    then IDLE;

                // Global SoC override
                transition idleToSafe
                    first IDLE
                    if socPercent < 15.0
                    then SAFE;
                transition acquisitionToSafe
                    first NADIR_ACQUISITION
                    if socPercent < 15.0
                    then SAFE;
                transition manoeuvringToSafe
                    first MANOEUVRING
                    if socPercent < 15.0
                    then SAFE;
                transition trackingToSafe
                    first TARGET_TRACKING
                    if socPercent < 15.0
                    then SAFE;
                transition downlinkToSafe
                    first DOWNLINK
                    if socPercent < 15.0
                    then SAFE;
            }
        }

        // =====================================================================
        // SDA Actions — Data Pipeline & Demo 2 Manoeuvre Actions
        // =====================================================================
        package 'SDA Actions' {

            // ── Atomic Action Definitions ──────────────────────────────────

            action def ComputeSwathAction {
                doc /* Computes swath width from altitude and FOV.
                     * Formula: swathKm = 2 × alt × tan(fov/2)
                     * [L2-REQ-010, L2-REQ-011] */
                in  attribute fov   : RealDeg;
                in  attribute alt   : RealKm;
                out attribute swath : RealKm;
            }

            action def EnvironmentClassificationAction {
                doc /* Classifies each swath interval as Day/Night (SPICE
                     * solar elevation) and Land/Ocean (global-land-mask).
                     * Applies Land Priority [L2-REQ-022] and Day Priority
                     * [L2-REQ-023] overrides. Sends classification tag to CDH
                     * for Apply_Rate_Profile.  executed by ACSSubsystem.
                     * [L2-REQ-020, L2-REQ-021, L2-REQ-022, L2-REQ-023] */
                in  attribute satPositionECI : ScalarValues::Real;
                in  attribute utcTime        : ScalarValues::String;
                in  attribute swath          : RealKm;
                out attribute isDayFlag      : ScalarValues::Boolean;
                out attribute isLandFlag     : ScalarValues::Boolean;
                out attribute landPriority   : ScalarValues::Boolean;
            }

            action def DataRateSelectionAction {
                doc /* Selects data rate from resolved environment class.
                     *   LAND_DAY   → 100 Mbps [L2-REQ-031]
                     *   LAND_NIGHT →  50 Mbps [L2-REQ-032]
                     *   OCEAN      →  10 Mbps [L2-REQ-031]
                     * LandPriority override applied before Ocean rule
                     * [L2-REQ-022]. */
                in  attribute isDay        : ScalarValues::Boolean;
                in  attribute isLand       : ScalarValues::Boolean;
                in  attribute landPriority : ScalarValues::Boolean;
                out attribute rate         : RealMbps;
            }

            action def StorageManagementAction {
                doc /* Updates OBC recorder fill level.
                     * Enforces Drop-Newest overflow policy if
                     * (fill + generated) > capacity.
                     * [L2-REQ-040, L2-REQ-041, L2-REQ-043, L2-REQ-044] */
                in  attribute rate       : RealMbps;
                in  attribute capGB      : RealGB;
                in  attribute prevFillGB : RealGB;
                out attribute fillGB     : RealGB;
                out attribute lossGB     : RealGB;
            }

            action def CoverageGridUpdateAction {
                doc /* Updates 5°×5° global grid (2592 cells).
                     * Marks cells covered when swath footprint intersects.
                     * [L2-REQ-012, L2-REQ-013, L2-REQ-014, L2-REQ-015] */
                in  attribute groundTrackLat : RealDeg;
                in  attribute groundTrackLon : RealDeg;
                in  attribute swath          : RealKm;
                out attribute deltaPercent   : RealPct;
            }

            action def TorqueComputationAction {
                doc /* Demo 2. Computes reaction-wheel torque for nadir→target
                     * slew. Notifies EPS of power spike via
                     * Report_Maneuver_Power.
                     * [DEMO2-REQ-002, DEMO2-REQ-005] */
                in  attribute currentAtt_deg    : RealDeg;
                in  attribute targetLat_deg     : RealDeg;
                in  attribute targetLon_deg     : RealDeg;
                in  attribute spacecraftInertia : ScalarValues::Real;
                out attribute torque_nm         : RealNm;
                out attribute maneuverPower_w   : RealW;
                out attribute slewDuration_s    : ScalarValues::Real;
            }

            action def DownlinkAction {
                doc /* Evaluates LoS, opens RF link, transmits
                     * Science_Data_Packet, confirms volume reduction to CDH.
                     * executed by MissionTTCSubsystem.
                     * [L2-REQ-050, L2-REQ-051, L2-REQ-052, L2-REQ-053] */
                in  attribute gsElevationDeg  : RealDeg;
                in  attribute recorderFillGB  : RealGB;
                in  attribute downlinkMbps    : RealMbps;
                out attribute dataDownlinked  : RealGB;
                out attribute sessionSuccess  : ScalarValues::Boolean;
            }

            // ── Data Acquisition Pipeline ──────────────────────────────────
            // Executes within NADIR_ACQUISITION state (do action runDataPipeline).
            // Sequential 5-step flow; no parallel fork at this level.
            // [L2-REQ-010 through L2-REQ-044]

            action def DataAcquisitionPipeline {
                doc /* Top-level data acquisition pipeline.
                     * Invoked each propagation time step by the CDH orchestrator
                     * while in NADIR_ACQUISITION state.
                     * EnvironmentClassificationAction executed by
                     * ACSSubsystem (nested within GNCSubsystem). */

                // Input parameters (bound from MissionSpacecraft attributes)
                in attribute fovDeg        : RealDeg  = new RealDeg(60.0);   // [L2-REQ-010]
                in attribute altitudeKm    : RealKm   = new RealKm(750.0);  // [L2-REQ-001]
                in attribute recorderCapGB : RealGB   = new RealGB(100.0);  // [L2-REQ-040]
                in attribute downlinkMbps  : RealMbps = new RealMbps(250.0);// [L2-REQ-052]

                // Output parameters (written back to mission state)
                out attribute swathKm        : RealKm;
                out attribute coverageDelta  : RealPct;
                out attribute dataRateMbps   : RealMbps;
                out attribute recorderFillGB : RealGB;
                out attribute dataLossGB     : RealGB;

                // Step 1 — Swath Computation [L2-REQ-010]
                action computeSwath : ComputeSwathAction {
                    in  fov   = fovDeg;
                    in  alt   = altitudeKm;
                    out swathKm;
                }

                // Step 2 — Environment Classification [L2-REQ-020-023]
                //  performed by ACSSubsystem within GNCSubsystem
                action classifyEnvironment : EnvironmentClassificationAction {
                    in  satPositionECI = 0.0;   // injected by CDH orchestrator
                    in  utcTime        = "";    // injected by CDH orchestrator
                    in  swath          = swathKm;
                    out isDayFlag;
                    out isLandFlag;
                    out landPriority;
                }

                // Step 3 — Data Rate Selection [L2-REQ-031-032]
                action selectDataRate : DataRateSelectionAction {
                    in  isDay        = classifyEnvironment::isDayFlag;
                    in  isLand       = classifyEnvironment::isLandFlag;
                    in  landPriority = classifyEnvironment::landPriority;
                    out dataRateMbps;
                }

                // Step 4 — OBC Recorder Update [L2-REQ-040-044]
                action updateStorage : StorageManagementAction {
                    in  rate       = dataRateMbps;
                    in  capGB      = recorderCapGB;
                    in  prevFillGB : RealGB = new RealGB(0.0);   // bound to running fill by orchestrator
                    out fillGB;
                    out lossGB;
                }

                // Step 5 — Coverage Grid Update [L2-REQ-012-015]
                action updateCoverageGrid : CoverageGridUpdateAction {
                    in  groundTrackLat : RealDeg = new RealDeg(0.0);  // injected by CDH orchestrator
                    in  groundTrackLon : RealDeg = new RealDeg(0.0);  // injected by CDH orchestrator
                    in  swath          = swathKm;
                    out coverageDelta;
                }

                // Sequential flow
                flow computeSwath.swathKm to classifyEnvironment.swath;
                flow classifyEnvironment.isDayFlag to selectDataRate.isDay;
                flow selectDataRate.dataRateMbps to updateStorage.rate;
                flow computeSwath.swathKm to updateCoverageGrid.swath;
            }

            // ── Demo 2 Manoeuvre Pipeline ──────────────────────────────────
            // Executes within MANOEUVRING and TARGET_TRACKING states.
            // Invoked after OBC.parseAndDispatch dispatches the Execute_Slew
            // command received from TT&C uplink (Phase 1 command chain).

            action def Demo2ManoeuvreSequence {
                doc /* Full Demo 2 dynamic slew-and-observe sequence.
                     * Phase 2 (Execution):   TorqueComputationAction → slewToTarget
                     * Phase 3 (Observation): activateHighRateObservation
                     * Phase 4 (Reporting):   slewToNadir (TT&C downlinks handled
                     *                        by MissionTTCSubsystem post-sequence). */

                in  attribute currentAtt_deg   : RealDeg;
                in  attribute targetLat_deg    : RealDeg;
                in  attribute targetLon_deg    : RealDeg;

                out attribute torque_nm        : RealNm;
                out attribute maneuverPower_w  : RealW;
                out attribute slewDuration_s   : ScalarValues::Real;

                // Step 1 — Torque Computation [DEMO2-REQ-002, DEMO2-REQ-005]
                //  executed by ACSSubsystem; power reported to EPS
                action computeTorque : TorqueComputationAction {
                    in  currentAtt_deg    = currentAtt_deg;
                    in  targetLat_deg     = targetLat_deg;
                    in  targetLon_deg     = targetLon_deg;
                    in  spacecraftInertia = 1.0;  // TBD: ACS inertia tensor
                    out torque_nm;
                    out maneuverPower_w;
                    out slewDuration_s;
                }

                // Step 2 — Slew Execution [DEMO2-REQ-003]
                action slewToTarget {
                    doc /* ACS rotates spacecraft via ReactionWheel[4].
                         * Guard: pointingAchieved == true to exit
                         * MANOEUVRING → TARGET_TRACKING. */
                    in  torque_nm        : RealNm;
                    out pointingAchieved : ScalarValues::Boolean;
                }

                // Step 3 — High-Rate Observation [DEMO2-REQ-004]
                action activateHighRateObservation {
                    doc /* GNC(ACS) → CDH: Observation_Active tag.
                         * CDH switches to HIGH_RATE; Science Instrument
                         * data stream stored in OBC DataStorage. */
                    in  pointingAchieved  : ScalarValues::Boolean;
                    out observationActive : ScalarValues::Boolean;
                }

                // Step 4 — Return to Nadir [DEMO2-REQ-006]
                action slewToNadir {
                    doc /* ACS returns to nadir-pointing.
                         * acs_mode = NADIR; TARGET_TRACKING → NADIR_ACQUISITION. */
                    in  observationActive : ScalarValues::Boolean;
                }

                // Sequential flow
                flow computeTorque.torque_nm              to slewToTarget.torque_nm;
                flow slewToTarget.pointingAchieved        to activateHighRateObservation.pointingAchieved;
                flow activateHighRateObservation.observationActive to slewToNadir.observationActive;
            }
        }
    }

    // =========================================================================
    // 5-Analysis
    // =========================================================================
    package '5-Analysis';

    // =========================================================================
    // 6-Spacecraft
    // =========================================================================
    package '6-Spacecraft' {

        // ─────────────────────────────────────────────────────────────────────
        // Requirements moved to: 'Spacecraft Mission — Integrated' > '1-Requirements'
        // Spacecraft part def moved to: 'Spacecraft Mission — Integrated' > '2-Structure'
        // ─────────────────────────────────────────────────────────────────────
        package 'Black-box Specification';

        // ─────────────────────────────────────────────────────────────────────
        // Physical Architecture
        // ─────────────────────────────────────────────────────────────────────
        package 'Physical Architecture' {
            package '1-Requirements';

            // ── 2-Structure: SpacecraftPhysical ──────────────────────────────
            // The perform action 'Collect And Downlink Observation Data' is the
            // single physical action flow that backs all use case perform steps.
            // Mission subsystem parts (from '4-Subsystems' > 'Mission Subsystems')
            // specialise (:>) the physical subsystem parts defined here.
            package '2-Structure' {
                view 'Spacecraft Physical Decomposition';

                part def SpacecraftPhysical :> 'Spacecraft Mission — Integrated'::'2-Structure'::Spacecraft {
                    // Physical subsystem parts — each typed by a physical part def
                    // Mission subsystems specialise these in 'Mission Subsystems'
                    part 'Onboard Computer';
                    part 'Avionics Subsystem' : '4-Subsystems'::'Avionics Subsystem'::AvionicsSubsystem {
                        perform 'Collect And Downlink Observation Data'.'Generate System Commands';
                        perform 'Collect And Downlink Observation Data'.'Store Data';
                        perform 'Collect And Downlink Observation Data'.'Process Downlink Data';
                    }
                    part 'Communication Subsystem' : '4-Subsystems'::'Communication Subsystem'::CommunicationsSubsystem {
                        perform 'Collect And Downlink Observation Data'.'Downlink Data';
                    }
                    part 'Propulsion Subsystem'  : '4-Subsystems'::'Propulsion Subsystem'::PropulsionSubsystem;
                    part 'GN&C Subsystem'        : '4-Subsystems'::'GN&C Subsystem'::GNCSubsystem;
                    part 'Thermal Subsystem'     : '4-Subsystems'::'Thermal Subsystem'::ThermalSubsystem;
                    part 'Power Subsystem'       : '4-Subsystems'::'Power Subsystem'::PowerSubsystem;
                    part 'Structure and Mechanisms Subsystem' : '4-Subsystems'::'Structure and Mechanisms Subsystems'::StructureAndMechanismsSubsystem {
                        part Separation_Subsystem :>> separationSubsystem;
                        part Frame_               :>> Frame;
                        part Panel_               :>> panel;
                    }
                    part 'Harness Subsystem' : '4-Subsystems'::'Harness Subsystem'::'Harness Subsystem' {
                        part LV_Electrical_Harness :>> 'LV Electrical Harness';
                        part Power_Harness         :>> 'Power Harness';
                        part Data_Harness          :>> 'Data Harness';
                    }
                    part 'Payload Subsystem' : '4-Subsystems'::'Payload Subsystem'::'Payload Subsystem' {
                        perform 'Collect And Downlink Observation Data'.'Sensor and Signal management';
                        part Signal_Processor :>> 'Signal Processor' {
                            perform 'Sensor and Signal management'.'Process Signal';
                        }
                        part Payload_Sensor :>> 'Payload Sensor' {
                            perform 'Sensor and Signal management'.'Sense Thermal Emissions';
                        }
                        part Payload_SW :>> 'Payload SW' {
                            perform 'Spacecraft Mission — Integrated'::'6-Spacecraft'::'Physical Architecture'::'2-Structure'::SpacecraftPhysical::'Payload Subsystem'::'Sensor and Signal management'.'Control Sensor';
                        }
                        view 'Sensor and Signal Management ACT';
                        perform 'Sensor and Signal management' {
                            connect Emissions to 'Sense Thermal Emissions'.Emissions;
                            connect 'Sense Thermal Emissions'.Signal to 'Process Signal'.Signal;
                            connect 'Process Signal'.Signal to Signal;
                            connect 'Control Sensor'.'Sensor CMD' to 'Sense Thermal Emissions'.'Sensor CMD';
                            connect 'Control Sensor'.'System Commands' to 'System Commands';
                        }
                    }

                    // ── Physical action flow (10.0 origin, preserved verbatim) ──
                    // This is the single source of truth for the data pipeline.
                    // Use case perform steps reference the named actions here:
                    //   'Generate System Commands' ← Avionics
                    //   'Sensor and Signal management' ← Payload
                    //   'Store Data'               ← Avionics (CDH/DataStorage)
                    //   'Process Downlink Data'    ← Avionics
                    //   'Downlink Data'            ← Communications
                    perform action 'Collect And Downlink Observation Data' {
                        in item Emissions;
                        out item 'Observation Data';

                        action 'Generate System Commands' {
                            out item 'System Commands';
                        }
                        action 'Sensor and Signal management' {
                            in item Emissions;
                            in item 'System Commands';
                            out item Signal;
                            action 'Sense Thermal Emissions' {
                                in item Emissions;
                                in item 'Sensor CMD';
                                out item Signal;
                            }
                            action 'Process Signal' {
                                in item Signal;
                                out item Signal;
                            }
                            action 'Control Sensor' {
                                in item 'System Commands';
                                out item 'Sensor CMD';
                            }
                        }
                        action 'Store Data' {
                            in item Signal;
                            out item 'Signal Data';
                        }
                        action 'Process Downlink Data' {
                            in item 'Signal Data';
                            out item 'Downlink Data';
                        }
                        action 'Downlink Data' {
                            in item 'Downlink Data';
                            out item 'Observation Data';
                        }

                        // Data flow connections (pipeline order)
                        connect Emissions to 'Sensor and Signal management'.Emissions;
                        connect 'Generate System Commands'.'System Commands' to 'Sensor and Signal management'.'System Commands';
                        connect 'Sensor and Signal management'.Signal to 'Store Data'.Signal;
                        connect 'Store Data'.'Signal Data' to 'Process Downlink Data'.'Signal Data';
                        connect 'Process Downlink Data'.'Downlink Data' to 'Downlink Data'.'Downlink Data';
                        connect 'Downlink Data'.'Observation Data' to 'Observation Data';
                    }
                }

                view 'Collect And Downlink Observation Data';
            }

            package '3-Behavior';

            // ── 4-Subsystems ─────────────────────────────────────────────────
            package '4-Subsystems' {

                // =============================================================
                // MISSION SUBSYSTEMS  
                // =============================================================
                // Logical bridge between mission layer UseCases and Requirements (v1) and physical layer (10.0).
                //
                // decomposition (from Avionics_Integrated_Use_Case.docx):
                //   Avionics = OBC + CDH + TT&C  ("thinking and talking" hardware)
                //   GNC      = navigation/pointing logic + ACS as execution arm
                //
                // Specialisation map:
                //   MissionGNCSubsystem    :> GNCSubsystem            (owns propagation +
                //                                                       coverage math)
                //     ACSSubsystem (nested)  — owns nadir pointing + Demo 2 manoeuvring
                //   MissionCDHSubsystem    :> AvionicsSubsystem        (OBC + CDH;
                //                                                       owns L2-REQ-030-044)
                //   MissionTTCSubsystem    :> CommunicationsSubsystem  (TT&C uplink/downlink;
                //                                                       owns L2-REQ-050-054)
                //   MissionEPSSubsystem    :> PowerSubsystem
                //   MissionSpacecraft      :> SpacecraftPhysical
                // =============================================================
                package 'Mission Subsystems' {
                    public import 'Spacecraft Mission — Integrated'::'2-Structure'::'Mission Types'::*;

                    // ── ACS — nested within MissionGNCSubsystem  ─────
                    //  ACS is the internal execution arm of GNC.
                    // Owns: nadir pointing (L2-REQ-002), environment classification
                    // (L2-REQ-020-023), all Demo 2 manoeuvring (DEMO2-REQ-001-003, 006).
                    // Sends: Apply_Rate_Profile(Tag) to CDH after classification.
                    // Receives: pointing setpoints from GNC; dispatched via OBC.
                    part def ACSSubsystem {
                        doc
                        /* Attitude Control System — internal execution arm of GNC .
                         * Physical realisation: GNCSubsystem > GNCSW (p1-p8),
                         *   ReactionWheel[4] (torque_if), GPSUnit (gps_if),
                         *   StarTracker (star_tracker_if), HorizonTracker, SunTracker,
                         *   Magnetometer, IMU.
                         * Responsibilities:
                         *   L2-REQ-002     — nadir pointing (acs_mode = NADIR)
                         *   L2-REQ-020-023 — Day/Night x Land/Ocean classification;
                         *                    sends Apply_Rate_Profile(Tag) to CDH
                         *   DEMO2-REQ-001  — target detection (acs_targetInView)
                         *   DEMO2-REQ-002  — torque computation (Compute_Control_Torque)
                         *   DEMO2-REQ-003  — slew manoeuvre (acs_mode = TARGET_TRACKING)
                         *   DEMO2-REQ-006  — return to nadir (acs_mode = NADIR) */

                        attribute acs_fov_deg          : RealDeg = new RealDeg(60.0);
                        attribute acs_altitude_km      : RealKm  = new RealKm(750.0);
                        attribute acs_mode             : ACSMode = ACSMode::NADIR;
                        attribute acs_gsElevation_deg  : RealDeg;   // current GS elevation angle
                        attribute acs_currentAtt_deg   : RealDeg;   // current pointing error
                        attribute acs_torque_nm        : RealNm;    // computed RW torque
                        attribute acs_swathKm          : RealKm;    // computed swath width
                        attribute acs_isDayFlag        : ScalarValues::Boolean;
                        attribute acs_isLandFlag       : ScalarValues::Boolean;
                        attribute acs_landPriority     : ScalarValues::Boolean = true;
                        attribute acs_targetInView     : ScalarValues::Boolean;
                        attribute acs_pointingAchieved : ScalarValues::Boolean;

                        action setNadirMode;        // acs_mode = NADIR [L2-REQ-002]
                        action classifyEnvironment; // Day/Night x Land/Ocean; tag to CDH [L2-REQ-020-023]
                        action computeSwath;        // acs_swathKm = f(altitude, fov) [L2-REQ-010]
                        action detectTargetInView;  // acs_targetInView via GPS+StarTracker [DEMO2-REQ-001]
                        action computeTorque;       // Compute_Control_Torque via RW[4] [DEMO2-REQ-002]
                        action slewToTarget;        // acs_mode = TARGET_TRACKING [DEMO2-REQ-003]
                        action slewToNadir;         // acs_mode = NADIR [DEMO2-REQ-006]
                    }

                    // ── GNC mission view  ─────────────────────────────
                    // GNC = "navigation and pointing" container.
                    // Contains ACSSubsystem as nested execution arm.
                    // GNC owns: orbital propagation (L2-REQ-060), coverage/swath math.
                    part def MissionGNCSubsystem :> 'GN&C Subsystem'::GNCSubsystem {
                        doc
                        /* Mission view of the GN&C Subsystem .
                         * Inherits: ReactionWheel[4] (torque_if), GNCSW (p1-p8),
                         *   GPSUnit (gps_if), StarTracker (star_tracker_if),
                         *   HorizonTracker, SunTracker, Magnetometer, IMU.
                         *   Ports: structural_if, inertial_ref_if, cmd_tlm_if,
                         *          thermal_if, pwr_if.
                         * Contains ACSSubsystem as nested part.
                         *   GNC owns: L2-REQ-060 (propagation via GPS + IMU),
                         *             L2-REQ-010/014 (coverage/swath math).
                         *   ACS owns: L2-REQ-002, L2-REQ-020-023,
                         *             DEMO2-REQ-001-003, DEMO2-REQ-006. */

                        attribute gnc_orbitalState : ScalarValues::String;  // current orbital state vector
                        attribute gnc_timeSync     : ScalarValues::Boolean; // time synchronisation flag

                        // ACS nested as internal execution arm 
                        part acs : ACSSubsystem;

                        action propagateOrbit; // gnc_orbitalState via GPS + IMU [L2-REQ-060]
                        action syncTime;       // gnc_timeSync; time synchronisation
                    }

                    // ── CDH / Avionics mission view  ──────────────────
                    // Avionics = OBC + CDH + TT&C ("thinking and talking" hw).
                    // MissionCDHSubsystem covers OBC + CDH function.
                    // OBC runs CDH software; parseAndDispatch dispatches Demo 2 trigger
                    // from TT&C uplink to GNC(ACS). Owns: L2-REQ-030-044, DEMO2-REQ-004.
                    part def MissionCDHSubsystem :> 'Avionics Subsystem'::AvionicsSubsystem {
                        doc
                        /* Mission view of the Avionics Subsystem — OBC + CDH function .
                         * Inherits: CDH (obs_if, mission_if, gnd_if, tlm_if, cmd_if),
                         *   OnboardComputer (primary + backup), DataStorage,
                         *   FlightSoftware > MissionSoftware.
                         * OBC runs CDH software and manages TT&C hardware.
                         *   parseAndDispatch: OBC parses Execute_Slew uplink from TT&C
                         *   and dispatches manoeuvre trigger to GNC(ACS).
                         * Responsibilities: L2-REQ-030-044, DEMO2-REQ-004. */

                        attribute cdh_recorderCap_gb    : RealGB  = new RealGB(100.0); // L2-REQ-040 baseline
                        attribute cdh_downlinkRate_mbps : RealMbps;
                        attribute cdh_mode              : CDHMode = CDHMode::IDLE;
                        attribute cdh_recorderFill_gb   : RealGB;
                        attribute cdh_dataLoss_gb       : RealGB;
                        attribute cdh_totalGenerated_gb : RealGB;
                        attribute cdh_dataRateMbps      : RealMbps; // set by selectDataRate
                        attribute cdh_envClass          : EnvironmentClass; // set by ACS classification tag

                        action selectDataRate;        // cdh_dataRateMbps from ACS tag [L2-REQ-031]
                        action generateAndStoreData;  // Store Data in OBC DataStorage [L2-REQ-030,040]
                        action enforceOverflowPolicy; // Execute_Drop_Policy when fill >= cap [L2-REQ-043]
                        action activateObservation;   // cdh_mode = HIGH_RATE on ACS tag [DEMO2-REQ-004]
                        action updateCoverageGrid;    // mission_coverage_pct update [L2-REQ-011-013]
                        action parseAndDispatch;      // OBC parses TT&C uplink; dispatches to GNC(ACS) [DEMO2]
                    }

                    // ── TT&C mission view (renamed from MissionCommsSubsystem) ──
                    // TT&C owns the complete uplink/downlink chain:
                    //   Uplink:   Ground -> TT&C -> OBC.parseAndDispatch -> GNC(ACS)
                    //   Downlink: CDH -> TT&C -> Ground (Science_Data_Packet)
                    //   Health:   CDH -> TT&C -> Ground (Recorder_Occupancy_Status)
                    // Owns: L2-REQ-050-054, DEMO2 Target Command.
                    part def MissionTTCSubsystem :> 'Communication Subsystem'::CommunicationsSubsystem {
                        doc
                        /* Mission view of the Communication Subsystem — TT&C .
                         * Renamed from MissionCommsSubsystem.
                         * Inherits: LowRateAntenna[1..2], HighRateAntenna (250 Mbps),
                         *   Duplexer, LRXmitAmplifier, HRXmitAmplifier,
                         *   RFReceiverDecoder, RFXmitEncoder, CommunicationSW,
                         *   AntennaDeploymentMechanism, AntennaGimbal, AntennaControlUnit.
                         *   Ports: gndcmdAndDataif, observationdata_if, GndCmdAndTlmif,
                         *          missiondataif, cmdAndTlmif.
                         * TT&C owns complete uplink/downlink chain.
                         *   Uplink:   Ground -> TT&C -> OBC (Execute_Slew(Target_X))
                         *   Downlink: CDH -> TT&C -> Ground (Science_Data_Packet)
                         *   Health:   CDH -> TT&C -> Ground (Recorder_Occupancy_Status)
                         * Responsibilities: L2-REQ-050-054, DEMO2 Target Command. */

                        attribute tel_downlinkMbps      : RealMbps = new RealMbps(250.0); // L2-REQ-052
                        attribute tel_inContact         : ScalarValues::Boolean;
                        attribute tel_stationId         : ScalarValues::String;   // active GS identifier
                        attribute tel_dataDownlinked_gb : RealGB;

                        action evaluateLineOfSight;      // tel_inContact; acs_gsElevation_deg > 10 [L2-REQ-050]
                        action openRFLink;               // RF link via LRA/HRA [L2-REQ-051]
                        action receiveUplink;            // Execute_Slew(Target_X) from Ground [DEMO2-Target]
                        action transmitData;             // Science_Data_Packet 250 Mbps [L2-REQ-052]
                        action confirmDownlink;          // tel_dataDownlinked_gb; CDH fill reduced [L2-REQ-053]
                        action transmitHealthTelemetry;  // Recorder_Occupancy_Status to Ground [L2-REQ-042]
                        action closeRFLink;              // RF link deactivated [L2-REQ-054]
                    }

                    // ── EPS mission view ──────────────────────────────────────
                    //  receives Report_Maneuver_Power from GNC(ACS).
                    // Interface: GNCSubsystem.pwr_if -> PowerSubsystem.cmdtlm.
                    part def MissionEPSSubsystem :> 'Power Subsystem'::PowerSubsystem {
                        doc
                        /* Mission view of the Power Subsystem (EPS stub).
                         * Inherits: Battery (SoC via PowerTLM), SolarArray,
                         *   PowerConditioner, PowerSwitch, PowerDistribution,
                         *   PowerMgmtSW (cmd_if/tlm_if), ArrayDeploymentMechanism.
                         *   Ports: cmdtlm (CommandandTelemetryIF), ivpowerif,
                         *          solar_if, internal_pwr_if.
                         * Receives Report_Maneuver_Power from GNC(ACS)
                         *   via GNCSubsystem.pwr_if -> PowerSubsystem.cmdtlm.
                         * Full EPS model TBD. */

                        attribute eps_socPercent_pct   : RealPct;  // Battery SoC via PowerTLM
                        attribute eps_maneuverPower_w  : RealW;    // extra load during slew
                        attribute eps_orbitEstablished : ScalarValues::Boolean;

                        action monitorSoC;           // eps_socPercent_pct via Battery tlm_if
                        action monitorSoCRecovery;   // safe mode exit when SoC >= 30%
                        action notifyManeuverLoad;   // eps_maneuverPower_w (Report_Maneuver_Power) [DEMO2-REQ-005]
                    }

                    // ── Mission Spacecraft (SoI mission view) — ────────
                    // ttc replaces comms; gnc.acs.* for ACS actions.
                    // Subject type for all use cases and requirements.
                    part def MissionSpacecraft :> 'Physical Architecture'::'2-Structure'::SpacecraftPhysical {
                        doc
                        /* Mission view of SpacecraftPhysical .
                         * gnc : MissionGNCSubsystem — contains acs : ACSSubsystem
                         * cdh : MissionCDHSubsystem — OBC + CDH function
                         * ttc : MissionTTCSubsystem — TT&C uplink/downlink chain
                         * eps : MissionEPSSubsystem — EPS stub */

                        attribute mission_coverage_pct : RealPct; // L2-REQ-014 (target >= 99%)
                        attribute mission_missionDurH  : RealH;   // elapsed simulation time
                        attribute groundTarget_lat_deg : RealDeg; // Demo 2 target latitude
                        attribute groundTarget_lon_deg : RealDeg; // Demo 2 target longitude

                        part gnc : MissionGNCSubsystem   :>> 'GN&C Subsystem';
                        part cdh : MissionCDHSubsystem   :>> 'Avionics Subsystem';
                        //  ttc replaces comms; MissionTTCSubsystem owns RF chain
                        part ttc : MissionTTCSubsystem   :>> 'Communication Subsystem';
                        part eps : MissionEPSSubsystem   :>> 'Power Subsystem';

                        action establishOrbit;           // eps_orbitEstablished [L2-REQ-062]
                        action activateMissionMode;      // cdh_mode = ACQUISITION
                        action runAcquisitionCycle;      // orchestrates per-step pipeline
                        action manageOnboardStorage;     // CDH/OBC storage management loop
                        action downlinkViaGroundStation; // TT&C downlink session 
                    }

                    // ── External Actors ───────────────────────────────────────

                    part def GroundOperator {
                        doc
                        /* Human mission controller.
                         * Maps to: '9-Launch Operations Facility' (10.0).
                         * Sends Execute_Slew(Target_X) uplink via TT&C.
                         * Provides: mission schedule, config uploads, sim control.
                         * Receives: acquisition status, coverage reports, safe alerts,
                         *           observation reports (Demo 2 reporting phase). */
                    }

                    part def GroundStationNetwork {
                        doc
                        /* 9-station global baseline ground segment.
                         * Maps to: '7-Ground Station' (10.0) — to be elaborated.
                         * Terminal of TT&C uplink/downlink chain.
                         *   Uplink:   Ground -> TT&C -> OBC (Execute_Slew)
                         *   Downlink: TT&C -> Ground (Science_Data_Packet)
                         *   Health:   TT&C -> Ground (Recorder_Occupancy_Status)
                         * [L2-REQ-004] */
                        attribute stationCount      : ScalarValues::Integer = 9;
                        attribute elevationMask_deg : RealDeg = new RealDeg(10.0); // L2-REQ-050
                    }

                    part def EarthEnvironment {
                        doc
                        /* Physical environment providing observation inputs to GNC(ACS).
                         * Provides Land/Ocean masks and Solar Geometry to ACS.
                         * solarElevation_deg -> acs_isDayFlag (Day/Night classification)
                         * isDay             -> acs_isDayFlag
                         * Land/Ocean mask   -> acs_isLandFlag
                         * Drives L2-REQ-020-023 via ACSSubsystem.classifyEnvironment. */
                        attribute solarElevation_deg : RealDeg;
                        attribute isDay              : ScalarValues::Boolean;
                    }

                    part def GroundTarget {
                        doc
                        /* Demo 2 external actor providing Uplink_Target_Coords.
                         * Coordinates uploaded via Ground -> TT&C -> OBC chain.
                         * target_lat/lon_deg -> spacecraft.groundTarget_lat/lon_deg
                         * Drives DEMO2-REQ-001 via ACSSubsystem.detectTargetInView. */
                        attribute target_lat_deg : RealDeg;
                        attribute target_lon_deg : RealDeg;
                        attribute target_id      : ScalarValues::String;
                    }

                    // — New actor (OI-09)
                    part def ScienceInstrument {
                        doc
                        /* Science Instrument — new external actor.
                         * Provides continuous science data stream to Avionics (OBC/CDH).
                         * Always powered on during Demo 1 nadir acquisition [L2-REQ-003].
                         * Data stream: ScienceInstrument -> Avionics (CDH) -> DataStorage.
                         * Full instrument model TBD. */
                        attribute instrument_dataRate_mbps : RealMbps;
                        attribute instrument_isActive      : ScalarValues::Boolean;
                    }

                    // ── System Context ────────────────────────────────────────
                    part def SpacecraftSystemContext {
                        doc
                        /* System context for the SDA mission .
                         * scienceInstrument actor added; comms -> ttc binding. */

                        part spacecraft        : MissionSpacecraft;
                        part groundOperator    : GroundOperator;
                        part groundNetwork     : GroundStationNetwork;
                        part earthEnv          : EarthEnvironment;
                        part groundTarget      : GroundTarget;
                        part scienceInstrument : ScienceInstrument; //  OI-09

                        use case demo1Mission
                            : 'Spacecraft Mission — Integrated'::'3-Use Cases'::'Acquire And Deliver Observation Data' {
                            subject :>> spacecraft        = spacecraft;
                            actor   :>> groundOperator    = groundOperator;
                            actor   :>> groundNetwork     = groundNetwork;
                            actor   :>> earthEnv          = earthEnv;
                            actor   :>> scienceInstrument = scienceInstrument;
                        }

                        use case demo2Manoeuvre
                            : 'Spacecraft Mission — Integrated'::'3-Use Cases'::'Perform Target Observation Manoeuvre' {
                            subject :>> spacecraft     = spacecraft;
                            actor   :>> groundTarget   = groundTarget;
                            actor   :>> groundOperator = groundOperator;
                        }

                        use case downlinkOp
                            : 'Spacecraft Mission — Integrated'::'3-Use Cases'::'Downlink Data To Ground Station' {
                            //  subject is ttc (MissionTTCSubsystem)
                            subject :>> ttc          = spacecraft.ttc;
                            actor   :>> groundNetwork = groundNetwork;
                        }

                        use case safeRecovery
                            : 'Spacecraft Mission — Integrated'::'3-Use Cases'::'Execute Safe Mode Recovery' {
                            subject :>> spacecraft    = spacecraft;
                            actor   :>> groundOperator = groundOperator;
                        }

                        use case envClassification
                            : 'Spacecraft Mission — Integrated'::'3-Use Cases'::'Perform Environmental Classification' {
                            subject :>> gnc    = spacecraft.gnc;
                            actor   :>> earthEnv = earthEnv;
                        }

                        use case storageOverflow
                            : 'Spacecraft Mission — Integrated'::'3-Use Cases'::'Manage Onboard Storage Overflow' {
                            subject :>> cdh = spacecraft.cdh;
                        }
                    }
                }

                // =============================================================
                // PHYSICAL SUBSYSTEM DEFINITIONS (10.0 origin — syntax-corrected)
                // =============================================================

                // ── Payload Subsystem ─────────────────────────────────────────
                package 'Payload Subsystem' {
                    view 'Payload Subsystem IBD';
                    part def 'Payload Subsystem' {
                        part 'Signal Processor' {
                            port 'sensor data if';
                            port port1;
                        }
                        part 'Payload Sensor' {
                            port __unnamed1;
                            port 'sensor data if';
                            port 'observation sensor if';
                        }
                        part 'Payload SW';
                        // FIX 10-S3: was bare typed feature; now 'part'
                        part sensorPointingMechanism : 'Structure and Mechanisms Subsystems'::SensorPointingMechanism;
                        view 'Payload Subsystem';
                        port 'observation sensor if';
                        // FIX 10-S4: single interface binding (duplicate removed)
                        interface 'observation sensor if' to 'Payload Sensor'.__unnamed1;
                        // FIX 10-S5: 'item emissions;' removed from part def
                        port 'observation data if';
                        connect 'Payload Sensor' to sensorPointingMechanism;
                        connect sensorPointingMechanism to 'Payload SW';
                        connect 'Payload Sensor' to 'Payload SW';
                        port 'cmd&tlm i/f' {
                            port 'cmd i/f';
                            port 'tlm i/f';
                        }
                        connect 'Payload SW' to 'cmd&tlm i/f';
                        connect 'Payload Sensor'.'sensor data if' to 'Signal Processor'.'sensor data if';
                        connect 'Signal Processor'.port1 to 'observation data if';
                        connect 'observation sensor if' to 'Payload Sensor'.__unnamed1;
                    }
                }

                // ── Avionics Subsystem ────────────────────────────────────────
                package 'Avionics Subsystem' {
                    item def ObservationData;
                    item def MissionData;
                    item def Command;
                    item def Telemetry;
                    interface def ObservationDataIF { flow observationData : ObservationData; }
                    interface def MissionDataIF     { flow missionData : MissionData; }
                    interface def CmdTlmIF          { flow cmd : Command; flow tlm : Telemetry; }
                    interface def CmdIF             { flow cmd : Command; }
                    interface def TlmIF             { flow tlm : Telemetry; }
                    part def SystemController;
                    part def FaultMgmtSW;
                    part def FlightSoftware {
                        part controller : SystemController;
                        part faultMgmt  : FaultMgmtSW;
                    }
                    part def MissionSoftware; // executes CDH mission actions
                    part def SoftwareSubsystem {
                        part flightSW : FlightSoftware {
                            part missionSW : MissionSoftware;
                        }
                    }
                    part def DataStorage;   // physical realisation of cdh_recorderCap_gb
                    part def OnboardComputer {
                        port p1 : CmdTlmIF;
                        part software : SoftwareSubsystem;
                    }
                    part def CDH {
                        port obs_if     : ObservationDataIF;
                        port mission_if : MissionDataIF;
                        port gnd_if     : CmdTlmIF;
                        port tlm_if     : TlmIF;
                        port cmd_if     : CmdIF;
                        port p5         : CmdTlmIF;
                    }
                    part def AvionicsSubsystem {
                        part cdh     : CDH;
                        part primary : OnboardComputer;
                        part backup  : OnboardComputer [0..1];
                        part storage : DataStorage;
                        port observation_if   : ObservationDataIF;
                        port mission_if       : MissionDataIF;
                        port gnd_cmd_tlm_if   : CmdTlmIF;
                        port tlm_if           : TlmIF;
                        port cmd_tlm_if       : CmdTlmIF;
                        connect observation_if.observationData to cdh.obs_if.observationData;
                        connect cdh.mission_if.missionData to mission_if.missionData;
                        connect gnd_cmd_tlm_if.cmd to cdh.gnd_if.cmd;
                        connect cdh.gnd_if.tlm to gnd_cmd_tlm_if.tlm;
                        connect cdh.tlm_if.tlm to tlm_if.tlm;
                        connect cmd_tlm_if.cmd to cdh.cmd_if.cmd;
                        connect cdh.p5.cmd to primary.p1.cmd;
                        connect primary.p1.tlm to cdh.p5.tlm;
                        connect cdh.p5.cmd to backup.p1.cmd;
                        connect backup.p1.tlm to cdh.p5.tlm;
                        connect primary.p1.cmd to backup.p1.cmd;
                        connect backup.p1.tlm to primary.p1.tlm;
                        connect primary.software to storage;
                        connect backup.software to storage;
                    }
                }

                // ── Communication Subsystem ───────────────────────────────────
                package 'Communication Subsystem' {
                    item def RF;
                    item def Command;
                    item def Telemetry;
                    item def ObservationData;
                    item def TelemetryRF;
                    item def ObservationDataRF;
                    interface def RF_IF        { flow rf   : RF; }
                    interface def Command_IF   { flow cmd  : Command; }
                    interface def Telemetry_IF { flow tlm  : Telemetry; }
                    interface def ObsData_IF   { flow data : ObservationData; }
                    part def LowRateAntenna            { port rfPort : RF_IF; }
                    part def HighRateAntenna           { port rfPort : RF_IF; }   // 250 Mbps [L2-REQ-052]
                    part def Duplexer                  { port rfPort : RF_IF; }
                    part def LRXmitAmplifier           { port rfPort : RF_IF; }
                    part def HRXmitAmplifier           { port rfPort : RF_IF; }
                    part def RFReceiverDecoder         { port cmdPort : Command_IF; port rfPort : RF_IF; }
                    part def RFXmitEncoder             { port rfPort : RF_IF;       port tlmPort : Telemetry_IF; }
                    part def CommunicationSW           { port cmdPort : Command_IF; port tlmPort : Telemetry_IF; port dataPort : ObsData_IF; }
                    part def AntennaDeploymentMechanism { port mechPort : RF_IF; }
                    part def AntennaGimbal             { port mechPort : RF_IF; }
                    part def AntennaControlUnit        { port ctrlPort : RF_IF; }
                    // FIX 10-S6: 'part' → 'part def' for reusability
                    part def CommunicationsSubsystem {
                        part lra    : LowRateAntenna [1..2];
                        part hra    : HighRateAntenna;
                        part duplex : Duplexer;
                        part lrAmp  : LRXmitAmplifier;
                        part hrAmp  : HRXmitAmplifier;
                        part rfRx   : RFReceiverDecoder;
                        part rfTx   : RFXmitEncoder;
                        part commSW : CommunicationSW;
                        part deploy : AntennaDeploymentMechanism [0..1];
                        part gimbal : AntennaGimbal [0..1];
                        part acu    : AntennaControlUnit [0..1];
                        port gndcmdAndDataif    : TelemetryRF;
                        // FIX 10-N1: typo 'oberservation' → 'observation'
                        port observationdata_if : ObservationDataRF;
                        port GndCmdAndTlmif {
                            port cmdif;
                            port tlmif : Telemetry;
                        }
                        port missiondataif : ObservationData;
                        port cmdAndTlmif;
                        connect lra.rfPort to duplex.rfPort { item rf : RF; }
                        connect lra to gndcmdAndDataif;
                        connect hra to observationdata_if;
                        connect commSW to missiondataif;
                        connect acu to cmdAndTlmif;
                        connect commSW to cmdAndTlmif;
                        connect deploy to cmdAndTlmif;
                        connect duplex.rfPort to rfRx.rfPort { item rf : RF; }
                        connect rfRx.cmdPort to GndCmdAndTlmif.cmdif { item cmd : Command; }
                        connect commSW.tlmPort to rfTx.tlmPort { item tlm : Telemetry; }
                        connect commSW to GndCmdAndTlmif.tlmif;
                        connect rfTx.rfPort to lrAmp.rfPort { item rf : RF; }
                        connect lrAmp.rfPort to duplex.rfPort { item rf : RF; }
                        connect rfTx.rfPort to hrAmp.rfPort { item rf : RF; }
                        connect hrAmp.rfPort to hra.rfPort { item rf : RF; }
                        // FIX 10-S9: nested connects lifted out of item-flow block
                        connect hra.rfPort to gimbal.mechPort;
                        connect gimbal.mechPort to acu.ctrlPort;
                        connect hra.rfPort to deploy.mechPort;
                    }
                }

                // ── Propulsion Subsystem ──────────────────────────────────────
                package 'Propulsion Subsystem' {
                    interface def CmdTlm_IF;
                    interface def Structural_IF;
                    interface def Thermal_IF;
                    interface def Power_IF;
                    interface def Thrust_IF;
                    item def PropulsionCMD;
                    item def Fuel;
                    item def Thrust;
                    part def PropulsionSW        { port cmdTlm : CmdTlm_IF; }
                    part def PropellantTank      { port fuelOut : CmdTlm_IF; }
                    part def Regulator           { port fuelIn : CmdTlm_IF; port fuelOut : CmdTlm_IF; }
                    part def PressurantTank      { port pressurantOut : CmdTlm_IF; }
                    part def PropellantLine      { port inlet : CmdTlm_IF;  port outlet : CmdTlm_IF; }
                    part def Nozzle              { port thrustOut : Thrust_IF; }
                    part def Thruster            { part nozzle : Nozzle; port thrustPort : Thrust_IF; }
                    part def PropulsionSubsystem {
                        part propulsionSW   : PropulsionSW;
                        part tank           : PropellantTank [1..2];
                        part regulator      : Regulator;
                        part pressurantTank : PressurantTank;
                        part propellantLine : PropellantLine;
                        part thruster       : Thruster [2..*];
                        port cmdTlm_if      : CmdTlm_IF;
                        port structural_if  : Structural_IF;
                        port thermal_if     : Thermal_IF;
                        port pwr_if         : Power_IF;
                        port thrust_if      : Thrust_IF;
                        connect cmdTlm_if to propulsionSW.cmdTlm;
                        connect tank.fuelOut to regulator.fuelIn;
                        connect regulator.fuelOut to pressurantTank.pressurantOut;
                        connect pressurantTank.pressurantOut to propellantLine.inlet;
                        connect propellantLine.outlet to thruster.thrustPort;
                        connect thruster.thrustPort to thrust_if;
                    }
                }

                // ── GN&C Subsystem ────────────────────────────────────────────
                // FIX 10-N2: all 'interface X' → 'interface def X'
                package 'GN&C Subsystem' {
                    interface def TorqueIF;
                    interface def StructuralIF;
                    interface def InertialReferenceIF;
                    interface def CmdTlmIF;
                    interface def IMUDataIF;
                    interface def GPSIF;
                    interface def StarTrackerIF;
                    interface def HorizonTrackerIF;
                    interface def SunTrackerIF;
                    interface def MagnetometerIF;
                    interface def ThermalIF;
                    interface def PowerIF;
                    part def ReactionWheel            { port torque_if : TorqueIF; port p1; }
                    part def InertialMeasurementUnit  { port inertial_ref_if : InertialReferenceIF; port p1; }
                    part def GNCSW                    { port p1; port p2; port p3; port p4; port p5; port p6; port p7; port p8; }
                    part def GPSUnit                  { port gps_if : GPSIF;                    port p1; }
                    part def StarTracker              { port star_tracker_if : StarTrackerIF;   port p1; }
                    part def HorizonTracker           { port horizon_tracker_if : HorizonTrackerIF; port p1; }
                    part def SunTracker               { port sun_tracker_if : SunTrackerIF;     port p1; }
                    part def Magnetometer             { port magnetometer_if : MagnetometerIF;  port p1; }
                    part def GNCSubsystem {
                        port structural_if   : StructuralIF;
                        port inertial_ref_if : InertialReferenceIF;
                        port cmd_tlm_if      : CmdTlmIF;
                        port thermal_if      : ThermalIF;
                        port pwr_if          : PowerIF;
                        part rw [4]              : ReactionWheel;
                        part imu               : InertialMeasurementUnit;
                        part gnc_sw            : GNCSW;
                        part gps [1]           : GPSUnit;
                        part starTracker [1]   : StarTracker;
                        part horizonTracker [1]: HorizonTracker;
                        part sunTracker [1]    : SunTracker;
                        part magnetometer [1]  : Magnetometer;
                        connect rw.torque_if to structural_if;
                        connect rw.p1 to gnc_sw.p8;
                        connect imu.inertial_ref_if to inertial_ref_if;
                        connect imu.p1 to gnc_sw.p2;
                        connect gnc_sw.p1 to cmd_tlm_if;
                        connect gps.p1 to gnc_sw.p7;
                        connect starTracker.p1 to gnc_sw.p6;
                        connect horizonTracker.p1 to gnc_sw.p5;
                        connect sunTracker.p1 to gnc_sw.p4;
                        connect magnetometer.p1 to gnc_sw.p3;
                        connect gps.gps_if to cmd_tlm_if;
                        connect starTracker.star_tracker_if to cmd_tlm_if;
                        connect horizonTracker.horizon_tracker_if to cmd_tlm_if;
                        connect sunTracker.sun_tracker_if to cmd_tlm_if;
                        connect magnetometer.magnetometer_if to cmd_tlm_if;
                        connect gnc_sw.p1 to thermal_if;
                        connect gnc_sw.p1 to pwr_if;
                    }
                }

                // ── Thermal Subsystem ─────────────────────────────────────────
                // FIX 10-N4: Heat/Temperature/ControlSignal/Fluid → 'item def'
                //            (used as flow types in interface def flows)
                package 'Thermal Subsystem' {
                    item def Heat;
                    item def Temperature;
                    item def ControlSignal;
                    item def Fluid;
                    interface def ThermalIF   { flow heat : Heat; }
                    interface def CmdTlmIF    { flow cmd : ControlSignal; flow tlm : Temperature; }
                    interface def RadiationIF { flow heat : Heat; }
                    part def Heater          { port thermal : ThermalIF; port control : CmdTlmIF; }
                    part def Thermistor      { port thermal : ThermalIF; port signal : CmdTlmIF; }
                    part def ThermalBlanket  { port thermal : ThermalIF; }
                    part def HeatPipe        { port thermal : ThermalIF; attribute ammonia : ScalarValues::String; }
                    part def Radiator        { port thermal : ThermalIF; port radiation : RadiationIF; }
                    part def ThermalControlSW {
                        port cmdTlm      : CmdTlmIF;
                        port controlPort : CmdTlmIF;
                        port signalPort  : CmdTlmIF;
                    }
                    part def ThermalSubsystem {
                        port internalThermalIF : ThermalIF;
                        port cmdTlmIF          : CmdTlmIF;
                        port radiationIF       : RadiationIF;
                        part heater     : Heater [0..*];
                        part blanket    : ThermalBlanket [0..*];
                        part heatPipe   : HeatPipe;
                        part radiator   : Radiator;
                        part controlSW  : ThermalControlSW;
                        part thermistor : Thermistor [0..*];
                        connect heater.thermal to internalThermalIF;
                        connect internalThermalIF to thermistor.thermal;
                        connect blanket.thermal to internalThermalIF;
                        connect internalThermalIF to heatPipe;
                        connect heatPipe.thermal to radiator.thermal;
                        connect radiator.radiation to radiationIF;
                        connect thermistor.signal to controlSW.signalPort;
                        connect controlSW.controlPort to heater.control;
                        connect controlSW.cmdTlm to cmdTlmIF;
                        comment BlanketNote about blanket
                        /* Blanket isolates thermal zones: no heat exchange with surroundings. */
                    }
                }

                // ── Power Subsystem ───────────────────────────────────────────
                // FIX 10-N3: 'interface X' → 'interface def X'
                // FIX 10-S2: duplicate empty part defs removed
                package 'Power Subsystem' {
                    interface def ElectricalPower;
                    interface def SwitchedPower;
                    interface def UnswitchedPower;
                    interface def SolarRadiation;
                    interface def PowerCMD;
                    interface def PowerTLM;
                    interface def CommandandTelemetryIF;
                    part def PowerMgmtSW {
                        port cmd_if : PowerCMD;
                        port tlm_if : PowerTLM;
                    }
                    part def Battery {
                        port pwr    : ElectricalPower;
                        port cmd_if : PowerCMD;
                        port tlm_if : PowerTLM;
                    }
                    part def PowerConditioner {
                        port p1        : ElectricalPower;
                        port p2        : UnswitchedPower;
                        port p3        : ElectricalPower;
                        port p4        : PowerTLM;
                        port ivpowerif : ElectricalPower;
                    }
                    part def PowerSwitch {
                        port p1 : UnswitchedPower;
                        port p2 : SwitchedPower;
                    }
                    part def PowerDistribution {
                        port inPort  : SwitchedPower;
                        port outPort : SwitchedPower;
                    }
                    part def ArrayPanel           { port pwr : ElectricalPower; }
                    part def SolarArrayGimbal;
                    part def ArrayDeploymentMechanism;
                    part def SolarArray {
                        port power_out : ElectricalPower;
                        port solar_in  : SolarRadiation;
                        part ap : ArrayPanel [1..*];
                        part g  : SolarArrayGimbal [0..1];
                    }
                    part def PowerSubsystem {
                        port cmdtlm          : CommandandTelemetryIF;
                        port ivpowerif       : ElectricalPower;
                        port solar_if        : SolarRadiation;
                        port internal_pwr_if : SwitchedPower;
                        part pmsw : PowerMgmtSW;
                        part bat  : Battery;
                        part pc   : PowerConditioner;
                        part psw  : PowerSwitch;
                        part pd   : PowerDistribution;
                        part sa   : SolarArray [1..*];
                        part adm  : ArrayDeploymentMechanism [0..1];
                        connect cmdtlm to pmsw;
                        connect pmsw.cmd_if to bat.cmd_if;
                        connect bat.tlm_if to pmsw.tlm_if;
                        connect bat.pwr to pc.p1;
                        connect sa.power_out to pc.p3;
                        connect solar_if to sa.solar_in;
                        connect pc.p2 to psw.p1;
                        connect pc.ivpowerif to ivpowerif;
                        connect psw.p2 to pd.inPort;
                        connect pd.outPort to internal_pwr_if;
                        connect pmsw to pc;
                        connect adm to sa;
                        connect pmsw to adm;
                    }
                }

                // ── Structure and Mechanisms Subsystems ───────────────────────
                // FIX 10-S7: separationSubsystem part declared before connect refs
                package 'Structure and Mechanisms Subsystems' {
                    interface def CmdTlmIF;
                    interface def InternalStructuralIF;
                    interface def DragIF;
                    interface def ImpactIF;
                    interface def LVSeparationIF;
                    interface def LVMechanicalIF;
                    part def AntennaGimbal;
                    part def SensorPointingMechanism;
                    part def AntennaControlUnit;
                    part def AntennaDeploymentMechanism;
                    part def ArrayDeploymentMechanism;
                    part def SolarArrayGimbal;
                    part def Frame;
                    part def Panel;
                    part def SeparationMechanism;
                    part def SeparationSubsystem {
                        part separationMechanism : SeparationMechanism;
                        port lvSepPort           : LVSeparationIF;
                    }
                    part def StructureAndMechanismsSubsystem {
                        port cmdTlm            : CmdTlmIF;
                        port internalStructural : InternalStructuralIF;
                        port dragPort          : DragIF;
                        port impactPort        : ImpactIF;
                        port lvMechPort        : LVMechanicalIF;
                        part antennaGimbal              : AntennaGimbal [0..1];
                        part sensorPointingMechanism    : SensorPointingMechanism [0..1];
                        part antennaControlUnit         : AntennaControlUnit [0..1];
                        part antennaDeploymentMechanism : AntennaDeploymentMechanism [0..1];
                        part arrayDeploymentMechanism   : ArrayDeploymentMechanism [0..1];
                        part solarArrayGimbal           : SolarArrayGimbal [0..2];
                        part Frame                      : Frame [1..*];
                        part panel                      : Panel [1..*];
                        // FIX 10-S8: declared before the connect statements that reference it
                        part separationSubsystem        : SeparationSubsystem;
                        connect cmdTlm to antennaGimbal;
                        connect cmdTlm to sensorPointingMechanism;
                        connect cmdTlm to antennaControlUnit;
                        connect cmdTlm to antennaDeploymentMechanism;
                        connect cmdTlm to arrayDeploymentMechanism;
                        connect cmdTlm to solarArrayGimbal;
                        connect cmdTlm to separationSubsystem.separationMechanism;
                        connect internalStructural to Frame;
                        connect internalStructural to antennaGimbal;
                        connect internalStructural to sensorPointingMechanism;
                        connect internalStructural to antennaControlUnit;
                        connect internalStructural to antennaDeploymentMechanism;
                        connect internalStructural to arrayDeploymentMechanism;
                        connect internalStructural to solarArrayGimbal;
                        connect Frame to panel;
                        connect Frame to lvMechPort;
                        connect panel to dragPort;
                        connect panel to impactPort;
                        connect Frame to separationSubsystem.separationMechanism;
                        connect separationSubsystem.lvSepPort to separationSubsystem.separationMechanism;
                        connect separationSubsystem.separationMechanism to lvMechPort;
                    }
                }

                // ── Harness Subsystem ─────────────────────────────────────────
                package 'Harness Subsystem' {
                    part def 'Harness Subsystem' {
                        part 'Power Harness';
                        part 'LV Electrical Harness';
                        part 'Data Harness';
                    }
                }
            }
        }

        package Verification;
    }

    // =========================================================================
    // 7-Ground Station
    // Hosts the GroundStationNetwork instances (9-station baseline).
    // Actors in use cases bind to these instances via GroundStationNetwork part def.
    // =========================================================================
    package '7-Ground Station';

    // =========================================================================
    // 8-Launch Vehicle
    // =========================================================================
    package '8-Launch Vehicle';

    // =========================================================================
    // 9-Launch Operations Facility
    // Hosts the GroundOperator instances.
    // Actors in use cases bind to these instances via GroundOperator part def.
    // =========================================================================
    package '9-Launch Operations Facility';

    // =========================================================================
    // 10-Supporting Elements
    // =========================================================================
    package '10-Supporting Elements';

    view 'Model Organization';
}
