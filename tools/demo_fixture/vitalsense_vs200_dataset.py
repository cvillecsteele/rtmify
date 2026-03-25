from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any


PRODUCT_FULL_IDENTIFIER = "VS-200-REV-C"
PRODUCT_NODE_ID = f"product://{PRODUCT_FULL_IDENTIFIER}"
PRODUCT_DESCRIPTION = "VitalSense VS-200 portable patient vital signs monitor"
REPO_PATH = "/demo/vitalsense-firmware"
HARDWARE_BOM_NAME = "main-pcba"
SOUP_BOM_NAME = "SOUP Components"
HARDWARE_BOM_ID = f"bom://{PRODUCT_FULL_IDENTIFIER}/hardware/{HARDWARE_BOM_NAME}"
SOUP_BOM_ID = f"bom://{PRODUCT_FULL_IDENTIFIER}/software/{SOUP_BOM_NAME}"
REQUIREMENT_CHANGED_AT = "2026-03-10T00:00:00Z"
REQUIREMENT_PREVIOUS_UPDATED_AT = "2026-03-05T00:00:00Z"
DEFAULT_CREATED_AT = "2026-03-01T00:00:00Z"


@dataclass(frozen=True)
class Product:
    assembly: str
    revision: str
    full_identifier: str
    description: str
    product_status: str


PRODUCT = Product(
    assembly="VS-200",
    revision="REV-C",
    full_identifier=PRODUCT_FULL_IDENTIFIER,
    description=PRODUCT_DESCRIPTION,
    product_status="Active",
)


USER_NEEDS: list[dict[str, str]] = [
    {
        "id": "UN-001",
        "statement": "Clinician shall be able to continuously monitor patient SpO2 at bedside",
        "source": "Clinical advisory board, 2024-Q2",
        "priority": "Critical",
    },
    {
        "id": "UN-002",
        "statement": "Clinician shall be able to view 3-lead ECG waveform in real time",
        "source": "Clinical advisory board, 2024-Q2",
        "priority": "Critical",
    },
    {
        "id": "UN-003",
        "statement": "Device shall alert clinician when vitals exceed configurable thresholds",
        "source": "Nurse practitioner interviews (N=12)",
        "priority": "Critical",
    },
    {
        "id": "UN-004",
        "statement": "Device shall operate on battery for a minimum of 8 hours during patient transport",
        "source": "EMS field observation, 2024-Q3",
        "priority": "High",
    },
    {
        "id": "UN-005",
        "statement": "Device shall transmit patient data to hospital EHR via HL7 FHIR",
        "source": "IT integration requirements, Memorial Hermann pilot",
        "priority": "High",
    },
    {
        "id": "UN-006",
        "statement": "Device shall be cleanable with standard hospital disinfectants without damage",
        "source": "Infection control officer feedback",
        "priority": "High",
    },
    {
        "id": "UN-007",
        "statement": "Clinician shall be able to review 24-hour trend data for all vital parameters",
        "source": "ICU nurse workflow study",
        "priority": "Medium",
    },
]


_REQUIREMENTS_WITH_TEXT: list[dict[str, Any]] = [
    {
        "id": "REQ-001",
        "statement": "The system shall measure SpO2 in the range 70-100% with accuracy +/-2% (Arms)",
        "priority": "Critical",
        "status": "Approved",
        "kind": "system",
        "parent_user_need_ids": ["UN-001"],
        "implemented_in": ["src/spo2/spo2_module.c", "src/spo2/motion_filter.c", "src/nibp/nibp_module.c", "src/temp/temp_sensor.c"],
        "tested_by": ["TG-SPO2", "TG-NIBP", "TG-TEMP", "TG-ATP"],
        "risk_ids": ["RSK-001", "RSK-008"],
    },
    {
        "id": "REQ-002",
        "statement": "The system shall acquire and display 3-lead ECG (Leads I, II, III) with a sample rate >= 500 sps",
        "priority": "Critical",
        "status": "Approved",
        "kind": "system",
        "parent_user_need_ids": ["UN-002"],
        "implemented_in": ["src/ecg/ecg_acquisition.c", "src/ecg/ecg_display.c"],
        "tested_by": ["TG-ECG", "TG-ATP"],
        "risk_ids": ["RSK-002"],
    },
    {
        "id": "REQ-003",
        "statement": "The system shall generate audible and visual alarms when any monitored parameter exceeds user-configured thresholds within 10 seconds",
        "priority": "Critical",
        "status": "Approved",
        "kind": "system",
        "parent_user_need_ids": ["UN-003"],
        "implemented_in": ["src/alarm/alarm_manager.c", "src/alarm/alarm_iec60601.c"],
        "tested_by": ["TG-ALARM", "TG-ATP"],
        "risk_ids": ["RSK-003"],
    },
    {
        "id": "REQ-004",
        "statement": "The system shall operate continuously for >= 8 hours on a fully charged battery under normal monitoring load",
        "priority": "High",
        "status": "Approved",
        "kind": "system",
        "parent_user_need_ids": ["UN-004"],
        "implemented_in": ["src/power/power_mgmt.c"],
        "tested_by": ["TG-PWR", "TG-ATP"],
        "risk_ids": ["RSK-004"],
    },
    {
        "id": "REQ-005",
        "statement": "The system shall transmit patient observation resources via HL7 FHIR R4 over TLS 1.2+",
        "priority": "High",
        "status": "Approved",
        "kind": "system",
        "parent_user_need_ids": ["UN-005"],
        "implemented_in": ["src/fhir/fhir_client.c", "src/fhir/fhir_bulk_export.c"],
        "tested_by": ["TG-FHIR"],
        "risk_ids": ["RSK-005", "RSK-010"],
    },
    {
        "id": "REQ-006",
        "statement": "All patient-contact enclosure surfaces shall withstand cleaning with 70% IPA and quaternary ammonium compounds per IEC 60601-1 section 11.6.6",
        "priority": "High",
        "status": "Approved",
        "kind": "system",
        "parent_user_need_ids": ["UN-006"],
        "implemented_in": ["src/enclosure/cleanability_spec.c"],
        "tested_by": ["TG-CLEAN"],
        "risk_ids": [],
    },
    {
        "id": "REQ-007",
        "statement": "The system shall store and display trend data for SpO2, HR, ECG rhythm, NIBP, and temperature for the preceding 24 hours",
        "priority": "Medium",
        "status": "Approved",
        "kind": "system",
        "parent_user_need_ids": ["UN-007"],
        "implemented_in": ["src/trend/trend_storage.c", "src/trend/trend_display.c", "src/fhir/fhir_bulk_export.c"],
        "tested_by": ["TG-TREND", "TG-FHIR"],
        "risk_ids": ["RSK-006"],
    },
    {
        "id": "SRS-001",
        "statement": "The SpO2 module shall compute oxygen saturation from the ratio of AC/DC components of red (660 nm) and infrared (940 nm) PPG signals using the calibrated R-curve lookup table",
        "priority": "Critical",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": ["REQ-001"],
        "safety_class": "B",
        "implemented_in": ["src/spo2/spo2_module.c"],
        "tested_by": ["TG-SPO2", "TG-ATP"],
        "risk_ids": ["RSK-001"],
    },
    {
        "id": "SRS-002",
        "statement": "The SpO2 module shall reject motion artifact using a 4th-order adaptive filter and shall flag readings with perfusion index < 0.5% as unreliable",
        "priority": "Critical",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": ["REQ-001"],
        "safety_class": "B",
        "implemented_in": ["src/spo2/motion_filter.c"],
        "tested_by": ["TG-SPO2"],
        "risk_ids": ["RSK-001"],
    },
    {
        "id": "SRS-003",
        "statement": "The ECG acquisition task shall sample the ADS1293 ADC at 512 sps per channel with 24-bit resolution and apply a 0.05-150 Hz bandpass filter",
        "priority": "Critical",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": ["REQ-002"],
        "safety_class": "B",
        "implemented_in": ["src/ecg/ecg_acquisition.c"],
        "tested_by": ["TG-ECG", "TG-ATP"],
        "risk_ids": ["RSK-002"],
    },
    {
        "id": "SRS-004",
        "statement": "The ECG display task shall render the filtered waveform at >= 30 fps with a sweep speed of 25 mm/s +/- 5%",
        "priority": "Critical",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": ["REQ-002"],
        "safety_class": "A",
        "implemented_in": ["src/ecg/ecg_display.c"],
        "tested_by": ["TG-ECG"],
        "risk_ids": [],
    },
    {
        "id": "SRS-005",
        "statement": "The alarm manager shall evaluate all active alarm conditions every 1 second and assert the highest-priority active alarm on both the piezo buzzer and the display alarm indicator within the REQ-003 10-second window",
        "priority": "Critical",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": ["REQ-003"],
        "safety_class": "B",
        "implemented_in": ["src/alarm/alarm_manager.c"],
        "tested_by": ["TG-ALARM", "TG-ATP"],
        "risk_ids": ["RSK-003"],
    },
    {
        "id": "SRS-006",
        "statement": "The alarm manager shall implement alarm delay, silencing, and escalation per IEC 60601-1-8 section 6.3",
        "priority": "Critical",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": ["REQ-003"],
        "safety_class": "B",
        "implemented_in": ["src/alarm/alarm_iec60601.c"],
        "tested_by": ["TG-ALARM"],
        "risk_ids": ["RSK-003"],
    },
    {
        "id": "SRS-007",
        "statement": "The power management module shall monitor battery SOC via the BQ25895 fuel gauge and shall initiate graceful shutdown with data flush when SOC < 5%",
        "priority": "High",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": ["REQ-004"],
        "safety_class": "B",
        "implemented_in": ["src/power/power_mgmt.c"],
        "tested_by": ["TG-PWR", "TG-ATP"],
        "risk_ids": ["RSK-004"],
    },
    {
        "id": "SRS-008",
        "statement": "The FHIR client shall serialize Observation resources conforming to US Core v5.0.1 profiles and POST them to a configurable FHIR server endpoint with mutual TLS authentication",
        "priority": "High",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": ["REQ-005"],
        "safety_class": "B",
        "implemented_in": ["src/fhir/fhir_client.c"],
        "tested_by": ["TG-FHIR"],
        "risk_ids": ["RSK-005", "RSK-010"],
    },
    {
        "id": "SRS-009",
        "statement": "The trend storage module shall write parameter snapshots to flash every 60 seconds and maintain a circular buffer covering >= 24 hours at normal monitoring load",
        "priority": "Medium",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": ["REQ-007"],
        "safety_class": "A",
        "implemented_in": ["src/trend/trend_storage.c"],
        "tested_by": ["TG-TREND"],
        "risk_ids": ["RSK-006"],
    },
    {
        "id": "SRS-010",
        "statement": "The trend display task shall render scrollable time-series plots for each parameter with pinch-to-zoom on the 5-inch touchscreen",
        "priority": "Medium",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": ["REQ-007"],
        "safety_class": "A",
        "implemented_in": ["src/trend/trend_display.c"],
        "tested_by": ["TG-TREND"],
        "risk_ids": [],
    },
    {
        "id": "SRS-011",
        "statement": "The watchdog supervisor shall reset the MCU if any safety-class B task misses its deadline by > 2x the task period",
        "priority": "High",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": [],
        "safety_class": "B",
        "implemented_in": ["src/safety/watchdog.c"],
        "tested_by": ["TG-SAFE"],
        "risk_ids": ["RSK-007"],
    },
    {
        "id": "SRS-012",
        "statement": "The device shall perform a power-on self-test of the AFE4400, ADS1293, display controller, Wi-Fi module, and flash memory, and shall refuse to enter monitoring mode if any POST check fails",
        "priority": "High",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": [],
        "safety_class": "B",
        "implemented_in": ["src/safety/post.c"],
        "tested_by": ["TG-SAFE", "TG-ATP"],
        "risk_ids": ["RSK-007"],
    },
    {
        "id": "SRS-013",
        "statement": "The NIBP measurement module shall perform oscillometric blood pressure determination and report systolic, diastolic, and MAP values within +/-3 mmHg (mean error) per ISO 81060-2",
        "priority": "High",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": ["REQ-001"],
        "safety_class": "B",
        "implemented_in": ["src/nibp/nibp_module.c"],
        "tested_by": ["TG-NIBP"],
        "risk_ids": ["RSK-008"],
    },
    {
        "id": "SRS-014",
        "statement": "The temperature module shall read the TMP117 sensor and report body temperature in the range 32-42C with accuracy +/-0.1C",
        "priority": "High",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": ["REQ-001"],
        "safety_class": "A",
        "implemented_in": ["src/temp/temp_sensor.c"],
        "tested_by": ["TG-TEMP"],
        "risk_ids": ["RSK-001"],
    },
    {
        "id": "SRS-015",
        "statement": "The FHIR client shall support bulk export of trend data as a FHIR Bundle resource containing up to 1,440 Observation resources (24h x 1/min)",
        "previous_statement": "The FHIR client shall support bulk export of trend data as a FHIR Bundle resource for daily export workflows",
        "priority": "High",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": ["REQ-005", "REQ-007"],
        "safety_class": "B",
        "implemented_in": ["src/fhir/fhir_bulk_export.c"],
        "tested_by": ["TG-FHIR"],
        "risk_ids": ["RSK-005"],
        "changed_at": REQUIREMENT_CHANGED_AT,
    },
    {
        "id": "SRS-016",
        "statement": "The system shall log all alarm events (assertion, acknowledgment, silencing, escalation) to non-volatile storage with UTC timestamp and operator ID",
        "priority": "Critical",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": ["REQ-003"],
        "safety_class": "B",
        "implemented_in": [],
        "tested_by": [],
        "risk_ids": ["RSK-003"],
    },
    {
        "id": "SRS-017",
        "statement": "The system shall support OTA firmware update with cryptographic signature verification (Ed25519) and automatic rollback on failed validation",
        "priority": "High",
        "status": "Approved",
        "kind": "software",
        "parent_requirement_ids": [],
        "safety_class": "B",
        "implemented_in": [],
        "tested_by": [],
        "risk_ids": ["RSK-009"],
    },
]


REQUIREMENT_TEXTS: dict[str, str] = {item["id"]: item["statement"] for item in _REQUIREMENTS_WITH_TEXT}
PREVIOUS_RTM_TEXTS: dict[str, str] = {
    item["id"]: item["previous_statement"]
    for item in _REQUIREMENTS_WITH_TEXT
    if "previous_statement" in item
}

REQUIREMENTS: list[dict[str, Any]] = [
    {
        key: value
        for key, value in item.items()
        if key not in {"statement", "previous_statement"}
    }
    for item in _REQUIREMENTS_WITH_TEXT
]

RTM_ARTIFACT_LOGICAL_KEY = "vitalsense-vs200-demo"
RTM_ARTIFACT_ID = f"artifact://rtm/{RTM_ARTIFACT_LOGICAL_KEY}"
RTM_ARTIFACT_DISPLAY_NAME = "VitalSense VS-200 RTM Workbook"
RTM_ARTIFACT_PATH_HINT = "workbook://vitalsense-vs200-demo"

SRS_ARTIFACT_LOGICAL_KEY = "vitalsense-vs200-srs"
SRS_ARTIFACT_ID = f"artifact://srs_docx/{SRS_ARTIFACT_LOGICAL_KEY}"
SRS_ARTIFACT_DISPLAY_NAME = "VitalSense VS-200 Software Requirements Specification"

SYSRD_ARTIFACT_LOGICAL_KEY = "vitalsense-vs200-sysrd"
SYSRD_ARTIFACT_ID = f"artifact://sysrd_docx/{SYSRD_ARTIFACT_LOGICAL_KEY}"
SYSRD_ARTIFACT_DISPLAY_NAME = "VitalSense VS-200 System Requirements Document"

ARTIFACT_INGESTED_AT = "2026-03-18T12:00:00Z"

ARTIFACTS: list[dict[str, str]] = [
    {
        "id": RTM_ARTIFACT_ID,
        "kind": "rtm_workbook",
        "logical_key": RTM_ARTIFACT_LOGICAL_KEY,
        "display_name": RTM_ARTIFACT_DISPLAY_NAME,
        "ingest_source": "fixture_rtm_seed",
        "last_ingested_at": ARTIFACT_INGESTED_AT,
    },
    {
        "id": SRS_ARTIFACT_ID,
        "kind": "srs_docx",
        "logical_key": SRS_ARTIFACT_LOGICAL_KEY,
        "display_name": SRS_ARTIFACT_DISPLAY_NAME,
        "ingest_source": "fixture_generated_docx",
        "last_ingested_at": ARTIFACT_INGESTED_AT,
    },
    {
        "id": SYSRD_ARTIFACT_ID,
        "kind": "sysrd_docx",
        "logical_key": SYSRD_ARTIFACT_LOGICAL_KEY,
        "display_name": SYSRD_ARTIFACT_DISPLAY_NAME,
        "ingest_source": "fixture_generated_docx",
        "last_ingested_at": ARTIFACT_INGESTED_AT,
    },
]


def _make_assertions(
    artifact_id: str,
    source_kind: str,
    req_ids: list[str],
    *,
    section: str,
    text_overrides: dict[str, str] | None = None,
) -> list[dict[str, Any]]:
    overrides = text_overrides or {}
    return [
        {
            "req_id": req_id,
            "artifact_id": artifact_id,
            "source_kind": source_kind,
            "section": section,
            "text": overrides.get(req_id, REQUIREMENT_TEXTS[req_id]),
            "parse_status": "ok",
            "occurrence_count": 1,
        }
        for req_id in req_ids
    ]


RTM_ASSERTION_REQ_IDS = [f"REQ-00{i}" for i in range(1, 8)] + [f"SRS-0{i:02d}" for i in range(1, 16)]
SRS_ASSERTION_REQ_IDS = [f"SRS-0{i:02d}" for i in range(1, 18)]
SYSRD_ASSERTION_REQ_IDS = [f"REQ-00{i}" for i in range(1, 8)]

REQUIREMENT_TEXT_ASSERTIONS: dict[str, list[dict[str, Any]]] = {
    RTM_ARTIFACT_ID: _make_assertions(
        RTM_ARTIFACT_ID,
        "rtm_workbook",
        RTM_ASSERTION_REQ_IDS,
        section="Requirements",
    ),
    SRS_ARTIFACT_ID: _make_assertions(
        SRS_ARTIFACT_ID,
        "srs_docx",
        SRS_ASSERTION_REQ_IDS,
        section="paragraph",
        text_overrides={"SRS-015": PREVIOUS_RTM_TEXTS["SRS-015"]},
    ),
    SYSRD_ARTIFACT_ID: _make_assertions(
        SYSRD_ARTIFACT_ID,
        "sysrd_docx",
        SYSRD_ASSERTION_REQ_IDS,
        section="table",
    ),
}


def artifact_assertions_for(artifact_id: str) -> list[dict[str, Any]]:
    return REQUIREMENT_TEXT_ASSERTIONS[artifact_id]


def requirement_text_node_id(artifact_id: str, req_id: str) -> str:
    for assertion in REQUIREMENT_TEXT_ASSERTIONS[artifact_id]:
        if assertion["req_id"] == req_id:
            return f"{artifact_id}:{req_id}"
    raise KeyError(f"no assertion for {req_id} under {artifact_id}")


SRS_DOC_PARAGRAPHS: list[str] = [
    f"{assertion['req_id']} - {assertion['text']}"
    for assertion in REQUIREMENT_TEXT_ASSERTIONS[SRS_ARTIFACT_ID]
]
SYSRD_DOC_ROWS: list[tuple[str, str]] = [
    (assertion["req_id"], assertion["text"])
    for assertion in REQUIREMENT_TEXT_ASSERTIONS[SYSRD_ARTIFACT_ID]
]

EXPECTED_CONFLICT_REQUIREMENTS = ["SRS-015"]
EXPECTED_SINGLE_SOURCE_REQUIREMENTS = ["SRS-016", "SRS-017"]
EXPECTED_MISSING_RTM_REQUIREMENTS = ["SRS-016", "SRS-017"]


TEST_GROUPS: list[dict[str, str]] = [
    {"id": "TG-SPO2", "name": "SpO2 Verification", "status": "Active"},
    {"id": "TG-ECG", "name": "ECG Verification", "status": "Active"},
    {"id": "TG-ALARM", "name": "Alarm Verification", "status": "Active"},
    {"id": "TG-PWR", "name": "Power Verification", "status": "Active"},
    {"id": "TG-FHIR", "name": "FHIR Verification", "status": "Active"},
    {"id": "TG-TREND", "name": "Trend Verification", "status": "Active"},
    {"id": "TG-SAFE", "name": "Safety Verification", "status": "Active"},
    {"id": "TG-NIBP", "name": "NIBP Verification", "status": "Active"},
    {"id": "TG-TEMP", "name": "Temperature Verification", "status": "Active"},
    {"id": "TG-ATP", "name": "Production ATP", "status": "Active"},
    {"id": "TG-CLEAN", "name": "Enclosure Cleanability Verification", "status": "Active"},
]


TEST_CASES: list[dict[str, str]] = [
    {"id": "TG-SPO2/TC-SPO2-001", "test_group_id": "TG-SPO2", "name": "TC-SPO2-001", "test_type": "Bench", "test_method": "BioTek Index 2XL SpO2 simulator", "status": "Active"},
    {"id": "TG-SPO2/TC-SPO2-002", "test_group_id": "TG-SPO2", "name": "TC-SPO2-002", "test_type": "Bench", "test_method": "Motion artifact rejection protocol", "status": "Active"},
    {"id": "TG-SPO2/TC-SPO2-003", "test_group_id": "TG-SPO2", "name": "TC-SPO2-003", "test_type": "Bench", "test_method": "Low perfusion accuracy", "status": "Active"},
    {"id": "TG-ECG/TC-ECG-001", "test_group_id": "TG-ECG", "name": "TC-ECG-001", "test_type": "Bench", "test_method": "ADS1293 sample rate verification", "status": "Active"},
    {"id": "TG-ECG/TC-ECG-002", "test_group_id": "TG-ECG", "name": "TC-ECG-002", "test_type": "Bench", "test_method": "Bandpass filter sweep", "status": "Active"},
    {"id": "TG-ECG/TC-ECG-003", "test_group_id": "TG-ECG", "name": "TC-ECG-003", "test_type": "System", "test_method": "Display frame rate measurement", "status": "Active"},
    {"id": "TG-ALARM/TC-ALM-001", "test_group_id": "TG-ALARM", "name": "TC-ALM-001", "test_type": "System", "test_method": "SpO2 low threshold trip timing", "status": "Active"},
    {"id": "TG-ALARM/TC-ALM-002", "test_group_id": "TG-ALARM", "name": "TC-ALM-002", "test_type": "System", "test_method": "Alarm priority arbitration", "status": "Active"},
    {"id": "TG-ALARM/TC-ALM-003", "test_group_id": "TG-ALARM", "name": "TC-ALM-003", "test_type": "System", "test_method": "Alarm silence and escalation", "status": "Active"},
    {"id": "TG-PWR/TC-PWR-001", "test_group_id": "TG-PWR", "name": "TC-PWR-001", "test_type": "System", "test_method": "Battery runtime", "status": "Active"},
    {"id": "TG-PWR/TC-PWR-002", "test_group_id": "TG-PWR", "name": "TC-PWR-002", "test_type": "System", "test_method": "Graceful shutdown data flush", "status": "Active"},
    {"id": "TG-FHIR/TC-FHIR-001", "test_group_id": "TG-FHIR", "name": "TC-FHIR-001", "test_type": "Integration", "test_method": "Observation POST to HAPI FHIR", "status": "Active"},
    {"id": "TG-FHIR/TC-FHIR-002", "test_group_id": "TG-FHIR", "name": "TC-FHIR-002", "test_type": "Integration", "test_method": "mTLS invalid-cert rejection", "status": "Active"},
    {"id": "TG-FHIR/TC-FHIR-003", "test_group_id": "TG-FHIR", "name": "TC-FHIR-003", "test_type": "Integration", "test_method": "Bulk export FHIR Bundle", "status": "Active"},
    {"id": "TG-TREND/TC-TRD-001", "test_group_id": "TG-TREND", "name": "TC-TRD-001", "test_type": "System", "test_method": "24-hour circular buffer wrap", "status": "Active"},
    {"id": "TG-TREND/TC-TRD-002", "test_group_id": "TG-TREND", "name": "TC-TRD-002", "test_type": "System", "test_method": "Trend display responsiveness", "status": "Active"},
    {"id": "TG-SAFE/TC-SAFE-001", "test_group_id": "TG-SAFE", "name": "TC-SAFE-001", "test_type": "Unit", "test_method": "Watchdog deadline miss reset", "status": "Active"},
    {"id": "TG-SAFE/TC-SAFE-002", "test_group_id": "TG-SAFE", "name": "TC-SAFE-002", "test_type": "System", "test_method": "POST forced failure handling", "status": "Active"},
    {"id": "TG-NIBP/TC-NIBP-001", "test_group_id": "TG-NIBP", "name": "TC-NIBP-001", "test_type": "Bench", "test_method": "ISO 81060-2 NIBP accuracy", "status": "Active"},
    {"id": "TG-TEMP/TC-TEMP-001", "test_group_id": "TG-TEMP", "name": "TC-TEMP-001", "test_type": "Bench", "test_method": "TMP117 water bath accuracy", "status": "Active"},
    {"id": "TG-ATP/TC-ATP-001", "test_group_id": "TG-ATP", "name": "TC-ATP-001", "test_type": "Production", "test_method": "Full POST sequence pass", "status": "Active"},
    {"id": "TG-ATP/TC-ATP-002", "test_group_id": "TG-ATP", "name": "TC-ATP-002", "test_type": "Production", "test_method": "SpO2 calibration and ECG self-test", "status": "Active"},
    {"id": "TG-ATP/TC-ATP-003", "test_group_id": "TG-ATP", "name": "TC-ATP-003", "test_type": "Production", "test_method": "Battery charge acceptance", "status": "Active"},
    {"id": "TG-ATP/TC-ATP-004", "test_group_id": "TG-ATP", "name": "TC-ATP-004", "test_type": "Production", "test_method": "Alarm response threshold trip", "status": "Active"},
    {"id": "TG-CLEAN/TC-CLEAN-001", "test_group_id": "TG-CLEAN", "name": "TC-CLEAN-001", "test_type": "Bench", "test_method": "Enclosure disinfectant wipe durability", "status": "Active"},
]


TEST_CASE_TO_REQUIREMENTS: dict[str, list[str]] = {
    "TG-SPO2/TC-SPO2-001": ["SRS-001"],
    "TG-SPO2/TC-SPO2-002": ["SRS-002"],
    "TG-SPO2/TC-SPO2-003": ["SRS-001"],
    "TG-ECG/TC-ECG-001": ["SRS-003"],
    "TG-ECG/TC-ECG-002": ["SRS-003"],
    "TG-ECG/TC-ECG-003": ["SRS-004"],
    "TG-ALARM/TC-ALM-001": ["SRS-005"],
    "TG-ALARM/TC-ALM-002": ["SRS-005"],
    "TG-ALARM/TC-ALM-003": ["SRS-006"],
    "TG-PWR/TC-PWR-001": ["SRS-007"],
    "TG-PWR/TC-PWR-002": ["SRS-007"],
    "TG-FHIR/TC-FHIR-001": ["SRS-008"],
    "TG-FHIR/TC-FHIR-002": ["SRS-008"],
    "TG-FHIR/TC-FHIR-003": ["SRS-015"],
    "TG-TREND/TC-TRD-001": ["SRS-009"],
    "TG-TREND/TC-TRD-002": ["SRS-010"],
    "TG-SAFE/TC-SAFE-001": ["SRS-011"],
    "TG-SAFE/TC-SAFE-002": ["SRS-012"],
    "TG-NIBP/TC-NIBP-001": ["SRS-013"],
    "TG-TEMP/TC-TEMP-001": ["SRS-014"],
    "TG-ATP/TC-ATP-001": ["SRS-012"],
    "TG-ATP/TC-ATP-002": ["SRS-001", "SRS-003"],
    "TG-ATP/TC-ATP-003": ["SRS-007"],
    "TG-ATP/TC-ATP-004": ["SRS-005"],
    "TG-CLEAN/TC-CLEAN-001": ["REQ-006"],
}


RISKS: list[dict[str, Any]] = [
    {"id": "RSK-001", "description": "Inaccurate SpO2 reading leads to delayed clinical intervention", "initial_severity": "5", "initial_likelihood": "2", "mitigation": "SRS-001 calibration, SRS-002 motion rejection, SRS-012 POST check", "residual_severity": "2", "residual_likelihood": "1", "status": "Mitigated", "requirement_ids": ["REQ-001", "SRS-001", "SRS-002"]},
    {"id": "RSK-002", "description": "ECG signal quality too poor for clinical interpretation", "initial_severity": "4", "initial_likelihood": "2", "mitigation": "SRS-003 filter design, SRS-012 POST check", "residual_severity": "2", "residual_likelihood": "1", "status": "Mitigated", "requirement_ids": ["REQ-002", "SRS-003"]},
    {"id": "RSK-003", "description": "Alarm failure - clinician not notified of critical parameter excursion", "initial_severity": "5", "initial_likelihood": "2", "mitigation": "SRS-005 alarm timing, SRS-006 escalation, SRS-011 watchdog", "residual_severity": "2", "residual_likelihood": "1", "status": "Mitigated", "requirement_ids": ["REQ-003", "SRS-005", "SRS-006"]},
    {"id": "RSK-004", "description": "Battery depletion during transport - loss of monitoring", "initial_severity": "4", "initial_likelihood": "2", "mitigation": "SRS-007 graceful shutdown with data preservation", "residual_severity": "2", "residual_likelihood": "1", "status": "Mitigated", "requirement_ids": ["REQ-004", "SRS-007"]},
    {"id": "RSK-005", "description": "Patient data transmitted insecurely to EHR", "initial_severity": "3", "initial_likelihood": "2", "mitigation": "SRS-008 mutual TLS", "residual_severity": "1", "residual_likelihood": "1", "status": "Mitigated", "requirement_ids": ["REQ-005", "SRS-008", "SRS-015"]},
    {"id": "RSK-006", "description": "Trend data loss - clinician cannot review patient history", "initial_severity": "3", "initial_likelihood": "2", "mitigation": "SRS-009 circular buffer with wear leveling", "residual_severity": "1", "residual_likelihood": "1", "status": "Mitigated", "requirement_ids": ["REQ-007", "SRS-009"]},
    {"id": "RSK-007", "description": "Software hang - device unresponsive during patient monitoring", "initial_severity": "5", "initial_likelihood": "2", "mitigation": "SRS-011 watchdog, SRS-012 POST", "residual_severity": "2", "residual_likelihood": "1", "status": "Mitigated", "requirement_ids": ["SRS-011", "SRS-012"]},
    {"id": "RSK-008", "description": "Inaccurate NIBP reading leads to missed hypertension/hypotension", "initial_severity": "4", "initial_likelihood": "2", "mitigation": "SRS-013 ISO 81060-2 validation", "residual_severity": "2", "residual_likelihood": "1", "status": "Mitigated", "requirement_ids": ["SRS-013"]},
    {"id": "RSK-009", "description": "Malicious firmware update compromises device integrity", "initial_severity": "4", "initial_likelihood": "1", "mitigation": "SRS-017 cryptographic verification plus rollback", "residual_severity": "2", "residual_likelihood": "1", "status": "Mitigated", "requirement_ids": ["SRS-017"]},
    {"id": "RSK-010", "description": "Known vulnerability in third-party SOUP component exploited in clinical network", "initial_severity": "4", "initial_likelihood": "3", "mitigation": "SOUP anomaly evaluation process, mbedTLS kept current", "residual_severity": "4", "residual_likelihood": "3", "status": "Open", "requirement_ids": ["SRS-008"]},
]


HARDWARE_BOM_ITEMS: list[dict[str, Any]] = [
    {"part": "PCBA-VS200", "revision": "C", "description": "Main controller PCBA", "parent_part": None, "parent_revision": None, "quantity": "1", "ref_designator": None, "supplier": "VitalSense (internal)", "category": "assembly", "requirement_ids": [], "test_ids": []},
    {"part": "STM32H743VIT6", "revision": "-", "description": "ARM Cortex-M7 MCU, 480 MHz", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "1", "ref_designator": "U1", "supplier": "STMicroelectronics", "category": "IC-MCU", "requirement_ids": ["SRS-011", "SRS-012"], "test_ids": ["TG-SAFE"]},
    {"part": "AFE4400RHAT", "revision": "-", "description": "Integrated analog front-end for SpO2", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "1", "ref_designator": "U2", "supplier": "Texas Instruments", "category": "IC-AFE", "requirement_ids": ["SRS-001", "SRS-002"], "test_ids": ["TG-SPO2"]},
    {"part": "ADS1293CISQ", "revision": "-", "description": "3-channel 24-bit ADC for biopotential measurement", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "1", "ref_designator": "U3", "supplier": "Texas Instruments", "category": "IC-ADC", "requirement_ids": ["SRS-003"], "test_ids": ["TG-ECG"]},
    {"part": "TMP117AIDRVR", "revision": "-", "description": "+/-0.1C digital temperature sensor", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "1", "ref_designator": "U4", "supplier": "Texas Instruments", "category": "IC-SENSOR", "requirement_ids": ["SRS-014"], "test_ids": ["TG-TEMP"]},
    {"part": "ILI9488", "revision": "-", "description": "320x480 TFT LCD driver", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "1", "ref_designator": "U5", "supplier": "Ilitek", "category": "IC-DISPLAY", "requirement_ids": ["SRS-004", "SRS-010"], "test_ids": ["TG-TREND"]},
    {"part": "ESP32-S3-WROOM-1-N8R8", "revision": "-", "description": "Wi-Fi module", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "1", "ref_designator": "U6", "supplier": "Espressif", "category": "MODULE-WIFI", "requirement_ids": ["SRS-008", "SRS-015"], "test_ids": ["TG-FHIR"]},
    {"part": "BQ25895RTWR", "revision": "-", "description": "Li-ion charger with fuel gauge", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "1", "ref_designator": "U7", "supplier": "Texas Instruments", "category": "IC-POWER", "requirement_ids": ["SRS-007"], "test_ids": ["TG-PWR"]},
    {"part": "TPS62130RGTR", "revision": "-", "description": "3A step-down converter", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "2", "ref_designator": "U8,U9", "supplier": "Texas Instruments", "category": "IC-POWER", "requirement_ids": [], "test_ids": []},
    {"part": "SI8621EC-B-IS", "revision": "-", "description": "Dual-channel digital isolator", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "2", "ref_designator": "U10,U11", "supplier": "Skyworks", "category": "IC-ISOLATOR", "requirement_ids": ["SRS-001", "SRS-003"], "test_ids": []},
    {"part": "BSS138LT1G", "revision": "-", "description": "N-channel MOSFET level shifter", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "6", "ref_designator": "Q1-Q6", "supplier": "onsemi", "category": "MOSFET", "requirement_ids": [], "test_ids": []},
    {"part": "CRCW04024K70FKED", "revision": "-", "description": "4.7 kohm chip resistor", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "24", "ref_designator": "R1-R24", "supplier": "Vishay", "category": "PASSIVE-R", "requirement_ids": [], "test_ids": []},
    {"part": "CL05B104KO5NNNC", "revision": "-", "description": "100 nF MLCC", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "32", "ref_designator": "C1-C32", "supplier": "Samsung Electro-Mechanics", "category": "PASSIVE-C", "requirement_ids": [], "test_ids": []},
    {"part": "GRM188R61A106ME69D", "revision": "-", "description": "10 uF MLCC", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "8", "ref_designator": "C33-C40", "supplier": "Murata", "category": "PASSIVE-C", "requirement_ids": [], "test_ids": []},
    {"part": "CGA3E1X7R1E475K080AC", "revision": "-", "description": "4.7 uF MLCC", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "4", "ref_designator": "C41-C44", "supplier": "TDK", "category": "PASSIVE-C", "requirement_ids": [], "test_ids": []},
    {"part": "BLM18PG221SN1D", "revision": "-", "description": "Ferrite bead, 220 ohm @ 100 MHz", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "6", "ref_designator": "FB1-FB6", "supplier": "Murata", "category": "PASSIVE-L", "requirement_ids": [], "test_ids": []},
    {"part": "BAT54SLT1G", "revision": "-", "description": "Dual Schottky diode", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "2", "ref_designator": "D1,D2", "supplier": "onsemi", "category": "DIODE", "requirement_ids": [], "test_ids": []},
    {"part": "DF12-60DP-0.5V(86)", "revision": "-", "description": "60-pin board-to-board connector", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "2", "ref_designator": "J1,J2", "supplier": "Hirose", "category": "CONNECTOR", "requirement_ids": [], "test_ids": []},
    {"part": "USB4110-GF-A", "revision": "-", "description": "USB Type-C receptacle", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "1", "ref_designator": "J3", "supplier": "GCT", "category": "CONNECTOR", "requirement_ids": [], "test_ids": []},
    {"part": "PKLCS1212E4001-R1", "revision": "-", "description": "Piezo buzzer", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "1", "ref_designator": "BZ1", "supplier": "Murata", "category": "BUZZER", "requirement_ids": ["SRS-005"], "test_ids": ["TG-ALARM"]},
    {"part": "ABM8-16.000MHZ-B2-T", "revision": "-", "description": "16 MHz crystal", "parent_part": "PCBA-VS200", "parent_revision": "C", "quantity": "1", "ref_designator": "Y1", "supplier": "Abracon", "category": "CRYSTAL", "requirement_ids": [], "test_ids": []},
]


SOUP_COMPONENTS: list[dict[str, Any]] = [
    {"component_name": "FreeRTOS", "version": "10.5.1", "supplier": "Amazon", "category": "RTOS", "license": "MIT", "purl": "pkg:github/FreeRTOS/FreeRTOS-Kernel@10.5.1", "safety_class": "B", "known_anomalies": "None known for 10.5.1", "anomaly_evaluation": "No anomalies applicable to VS-200 usage", "requirement_ids": ["SRS-011"], "test_ids": ["TG-SAFE"]},
    {"component_name": "lwIP", "version": "2.1.3", "supplier": "Swedish Institute of Computer Science", "category": "Network Stack", "license": "BSD-3-Clause", "purl": "pkg:generic/lwip@2.1.3", "safety_class": "A", "known_anomalies": "CVE-2020-22284 (buffer overflow in DNS). Fixed in 2.2.0.", "anomaly_evaluation": "VS-200 does not use lwIP DNS resolver; FHIR endpoint is configured by IP. CVE not applicable.", "requirement_ids": ["SRS-008"], "test_ids": ["TG-FHIR"]},
    {"component_name": "mbedTLS", "version": "3.4.0", "supplier": "ARM", "category": "TLS", "license": "Apache-2.0", "purl": "pkg:generic/mbedtls@3.4.0", "safety_class": "B", "known_anomalies": "CVE-2024-28960 (side-channel in RSA private key operations). Fixed in 3.6.0.", "anomaly_evaluation": "VS-200 uses mbedTLS for client-certificate TLS. RSA side-channel is exploitable on shared-host environments. VS-200 is a dedicated embedded device, not a shared host. Risk accepted per ISO 14971 residual risk evaluation. See RSK-010.", "requirement_ids": ["SRS-008"], "test_ids": ["TG-FHIR"]},
    {"component_name": "FatFs", "version": "R0.15", "supplier": "ChaN", "category": "Filesystem", "license": "Custom BSD-like", "purl": "pkg:generic/fatfs@R0.15", "safety_class": "A", "known_anomalies": "None known", "anomaly_evaluation": "No anomalies to evaluate", "requirement_ids": ["SRS-009"], "test_ids": ["TG-TREND"]},
    {"component_name": "littlefs", "version": "2.5.1", "supplier": "ARM", "category": "Filesystem", "license": "BSD-3-Clause", "purl": "pkg:generic/littlefs@2.5.1", "safety_class": "B", "known_anomalies": "None known for 2.5.1", "anomaly_evaluation": "No anomalies to evaluate", "requirement_ids": ["SRS-009"], "test_ids": ["TG-TREND"]},
    {"component_name": "STM32H7 HAL", "version": "1.11.1", "supplier": "STMicroelectronics", "category": "HAL", "license": "BSD-3-Clause", "purl": "pkg:generic/stm32h7-hal@1.11.1", "safety_class": "B", "known_anomalies": "None documented by ST for 1.11.1", "anomaly_evaluation": "No anomalies to evaluate", "requirement_ids": ["SRS-001", "SRS-003", "SRS-012"], "test_ids": ["TG-SPO2", "TG-ECG", "TG-SAFE"]},
    {"component_name": "cJSON", "version": "1.7.16", "supplier": "Dave Gamble", "category": "Serialization", "license": "MIT", "purl": "pkg:generic/cjson@1.7.16", "safety_class": "A", "known_anomalies": "None known", "anomaly_evaluation": "No anomalies to evaluate", "requirement_ids": ["SRS-008"], "test_ids": ["TG-FHIR"]},
    {"component_name": "zlib", "version": "1.2.11", "supplier": "Jean-loup Gailly and Mark Adler", "category": "Compression", "license": "zlib", "purl": "pkg:generic/zlib@1.2.11", "safety_class": "A", "known_anomalies": "CVE-2022-37434 (heap buffer overflow in inflate). Fixed in 1.2.12.", "anomaly_evaluation": "", "requirement_ids": ["SRS-015"], "test_ids": []},
    {"component_name": "Micro-ECC", "version": "unknown", "supplier": "Ken MacKay", "category": "Cryptography", "license": "BSD-2-Clause", "purl": "pkg:generic/micro-ecc@unknown", "safety_class": "B", "known_anomalies": "Unknown - version not pinned in build", "anomaly_evaluation": "", "requirement_ids": ["SRS-017"], "test_ids": []},
]


CI_EXECUTIONS: list[dict[str, Any]] = [
    {
        "execution_id": "ci-regression-20260305-001",
        "executed_at": "2026-03-05T22:14:00Z",
        "executor": {"system": "pytest", "version": "8.1.1"},
        "source": {"system": "github-actions", "workflow": "firmware-ci", "run_id": "9847231"},
        "test_cases": [
            {"result_id": "ci-001-spo2-cal", "test_case_ref": "TG-SPO2/TC-SPO2-001", "status": "passed", "duration_ms": 4200},
            {"result_id": "ci-001-spo2-motion", "test_case_ref": "TG-SPO2/TC-SPO2-002", "status": "passed", "duration_ms": 8700},
            {"result_id": "ci-001-spo2-lowpi", "test_case_ref": "TG-SPO2/TC-SPO2-003", "status": "passed", "duration_ms": 3100},
            {"result_id": "ci-001-ecg-sample", "test_case_ref": "TG-ECG/TC-ECG-001", "status": "passed", "duration_ms": 2800},
            {"result_id": "ci-001-ecg-filter", "test_case_ref": "TG-ECG/TC-ECG-002", "status": "passed", "duration_ms": 5600},
            {"result_id": "ci-001-ecg-fps", "test_case_ref": "TG-ECG/TC-ECG-003", "status": "passed", "duration_ms": 12400},
            {"result_id": "ci-001-alm-trip", "test_case_ref": "TG-ALARM/TC-ALM-001", "status": "passed", "duration_ms": 11200},
            {"result_id": "ci-001-alm-priority", "test_case_ref": "TG-ALARM/TC-ALM-002", "status": "passed", "duration_ms": 6300},
            {"result_id": "ci-001-alm-silence", "test_case_ref": "TG-ALARM/TC-ALM-003", "status": "passed", "duration_ms": 18500},
            {"result_id": "ci-001-pwr-runtime", "test_case_ref": "TG-PWR/TC-PWR-001", "status": "passed", "duration_ms": 3200, "notes": "Simulated load profile, not real 8hr test"},
            {"result_id": "ci-001-pwr-shutdown", "test_case_ref": "TG-PWR/TC-PWR-002", "status": "passed", "duration_ms": 4100},
            {"result_id": "ci-001-fhir-post", "test_case_ref": "TG-FHIR/TC-FHIR-001", "status": "passed", "duration_ms": 1800},
            {"result_id": "ci-001-fhir-tls", "test_case_ref": "TG-FHIR/TC-FHIR-002", "status": "passed", "duration_ms": 2200},
            {"result_id": "ci-001-fhir-bulk", "test_case_ref": "TG-FHIR/TC-FHIR-003", "status": "passed", "duration_ms": 9400},
            {"result_id": "ci-001-trend-wrap", "test_case_ref": "TG-TREND/TC-TRD-001", "status": "passed", "duration_ms": 7200},
            {"result_id": "ci-001-trend-display", "test_case_ref": "TG-TREND/TC-TRD-002", "status": "passed", "duration_ms": 3800},
            {"result_id": "ci-001-wdt-reset", "test_case_ref": "TG-SAFE/TC-SAFE-001", "status": "passed", "duration_ms": 2100},
            {"result_id": "ci-001-post-fail", "test_case_ref": "TG-SAFE/TC-SAFE-002", "status": "passed", "duration_ms": 14200},
            {"result_id": "ci-001-nibp-accuracy", "test_case_ref": "TG-NIBP/TC-NIBP-001", "status": "passed", "duration_ms": 6700},
            {"result_id": "ci-001-temp-accuracy", "test_case_ref": "TG-TEMP/TC-TEMP-001", "status": "passed", "duration_ms": 1900},
        ],
    },
    {
        "execution_id": "ci-regression-20260312-001",
        "executed_at": "2026-03-12T15:30:00Z",
        "executor": {"system": "pytest", "version": "8.1.1"},
        "source": {"system": "github-actions", "workflow": "firmware-ci", "run_id": "9901442"},
        "test_cases": [
            {"result_id": "ci-002-spo2-cal", "test_case_ref": "TG-SPO2/TC-SPO2-001", "status": "passed", "duration_ms": 4100},
            {"result_id": "ci-002-spo2-motion", "test_case_ref": "TG-SPO2/TC-SPO2-002", "status": "passed", "duration_ms": 8500},
            {"result_id": "ci-002-ecg-sample", "test_case_ref": "TG-ECG/TC-ECG-001", "status": "passed", "duration_ms": 2700},
            {"result_id": "ci-002-fhir-post", "test_case_ref": "TG-FHIR/TC-FHIR-001", "status": "passed", "duration_ms": 1900},
            {"result_id": "ci-002-fhir-tls", "test_case_ref": "TG-FHIR/TC-FHIR-002", "status": "passed", "duration_ms": 2100},
            {"result_id": "ci-002-wdt-reset", "test_case_ref": "TG-SAFE/TC-SAFE-001", "status": "passed", "duration_ms": 2000},
        ],
    },
]


ATE_UNIT_1247: dict[str, Any] = {
    "execution_id": "ate-vs200-revc-unit1247-20260317T09:12:00Z",
    "executed_at": "2026-03-17T09:12:00Z",
    "serial_number": "UNIT-1247",
    "full_product_identifier": PRODUCT_FULL_IDENTIFIER,
    "executor": {"station": "ATE-01", "fixture": "FCT-VS200-REV-C", "software_version": "3.2.1"},
    "source": {"system": "production-ate", "procedure_id": "ATP-VS200", "procedure_revision": "C"},
    "test_cases": [
        {"result_id": "ate-1247-post", "test_case_ref": "TG-ATP/TC-ATP-001", "status": "passed", "duration_ms": 4200, "measurements": [{"name": "post_flash_check", "value": 1, "unit": "bool"}, {"name": "post_afe4400_check", "value": 1, "unit": "bool"}, {"name": "post_ads1293_check", "value": 1, "unit": "bool"}, {"name": "post_wifi_check", "value": 1, "unit": "bool"}]},
        {"result_id": "ate-1247-spo2-ecg", "test_case_ref": "TG-ATP/TC-ATP-002", "status": "passed", "duration_ms": 8100, "measurements": [{"name": "spo2_r_value_check", "value": 0.98, "unit": "ratio"}, {"name": "ecg_selftest_amplitude_mv", "value": 1.02, "unit": "mV"}]},
        {"result_id": "ate-1247-battery", "test_case_ref": "TG-ATP/TC-ATP-003", "status": "passed", "duration_ms": 12400, "measurements": [{"name": "charge_current_ma", "value": 1480, "unit": "mA"}, {"name": "fuel_gauge_soc_pct", "value": 100, "unit": "%"}]},
        {"result_id": "ate-1247-alarm", "test_case_ref": "TG-ATP/TC-ATP-004", "status": "passed", "duration_ms": 11800, "measurements": [{"name": "alarm_latency_ms", "value": 3200, "unit": "ms"}]},
    ],
}


ATE_UNIT_1246: dict[str, Any] = {
    "execution_id": "ate-vs200-revc-unit1246-20260317T08:44:00Z",
    "executed_at": "2026-03-17T08:44:00Z",
    "serial_number": "UNIT-1246",
    "full_product_identifier": PRODUCT_FULL_IDENTIFIER,
    "executor": {"station": "ATE-01", "fixture": "FCT-VS200-REV-C", "software_version": "3.2.1"},
    "source": {"system": "production-ate", "procedure_id": "ATP-VS200", "procedure_revision": "C"},
    "test_cases": [
        {"result_id": "ate-1246-post", "test_case_ref": "TG-ATP/TC-ATP-001", "status": "passed", "duration_ms": 4100},
        {"result_id": "ate-1246-spo2-ecg", "test_case_ref": "TG-ATP/TC-ATP-002", "status": "passed", "duration_ms": 7900, "measurements": [{"name": "spo2_r_value_check", "value": 1.01, "unit": "ratio"}, {"name": "ecg_selftest_amplitude_mv", "value": 0.98, "unit": "mV"}]},
        {"result_id": "ate-1246-battery", "test_case_ref": "TG-ATP/TC-ATP-003", "status": "passed", "duration_ms": 11800},
        {"result_id": "ate-1246-alarm", "test_case_ref": "TG-ATP/TC-ATP-004", "status": "failed", "duration_ms": 15200, "measurements": [{"name": "alarm_latency_ms", "value": 12400, "unit": "ms"}], "notes": "Alarm latency 12.4s exceeds 10s requirement. Piezo buzzer drive circuit suspect. Routed to NCR-2026-031."},
    ],
}


def generate_passing_ate_batch() -> list[dict[str, Any]]:
    executions: list[dict[str, Any]] = []
    start = datetime(2026, 3, 3, 8, 15, tzinfo=timezone.utc)
    stations = ("ATE-01", "ATE-01", "ATE-02", "ATE-02")
    for offset, serial_num in enumerate(range(1201, 1246)):
        executed_at = start + timedelta(minutes=27 * offset)
        station = stations[offset % len(stations)]
        serial = f"UNIT-{serial_num}"
        suffix = f"{serial_num}"
        alarm_latency = 3100 + (offset % 4) * 140
        executions.append(
            {
                "execution_id": f"ate-vs200-revc-unit{serial_num}-{executed_at.strftime('%Y%m%dT%H:%M:%SZ')}",
                "executed_at": executed_at.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "serial_number": serial,
                "full_product_identifier": PRODUCT_FULL_IDENTIFIER,
                "executor": {"station": station, "fixture": "FCT-VS200-REV-C", "software_version": "3.2.1"},
                "source": {"system": "production-ate", "procedure_id": "ATP-VS200", "procedure_revision": "C"},
                "test_cases": [
                    {"result_id": f"ate-{suffix}-post", "test_case_ref": "TG-ATP/TC-ATP-001", "status": "passed", "duration_ms": 4000 + (offset % 3) * 90},
                    {"result_id": f"ate-{suffix}-spo2-ecg", "test_case_ref": "TG-ATP/TC-ATP-002", "status": "passed", "duration_ms": 7800 + (offset % 5) * 80, "measurements": [{"name": "spo2_r_value_check", "value": round(0.98 + ((offset % 5) * 0.01), 2), "unit": "ratio"}, {"name": "ecg_selftest_amplitude_mv", "value": round(0.99 + ((offset % 3) * 0.01), 2), "unit": "mV"}]},
                    {"result_id": f"ate-{suffix}-battery", "test_case_ref": "TG-ATP/TC-ATP-003", "status": "passed", "duration_ms": 11900 + (offset % 4) * 110, "measurements": [{"name": "charge_current_ma", "value": 1460 + (offset % 4) * 10, "unit": "mA"}, {"name": "fuel_gauge_soc_pct", "value": 100, "unit": "%"}]},
                    {"result_id": f"ate-{suffix}-alarm", "test_case_ref": "TG-ATP/TC-ATP-004", "status": "passed", "duration_ms": 11600 + (offset % 6) * 60, "measurements": [{"name": "alarm_latency_ms", "value": alarm_latency, "unit": "ms"}]},
                ],
            }
        )
    return executions


ANNOTATIONS: list[dict[str, Any]] = [
    {"file_path": "src/spo2/spo2_module.c", "line_number": 42, "req_id": "SRS-001", "context": "// @req SRS-001 R-curve lookup table SpO2 computation", "file_kind": "source"},
    {"file_path": "src/spo2/motion_filter.c", "line_number": 18, "req_id": "SRS-002", "context": "// @req SRS-002 4th-order adaptive motion artifact filter", "file_kind": "source"},
    {"file_path": "src/ecg/ecg_acquisition.c", "line_number": 31, "req_id": "SRS-003", "context": "// @req SRS-003 ADS1293 512 sps acquisition", "file_kind": "source"},
    {"file_path": "src/ecg/ecg_display.c", "line_number": 55, "req_id": "SRS-004", "context": "// @req SRS-004 Waveform rendering at 30 fps", "file_kind": "source"},
    {"file_path": "src/alarm/alarm_manager.c", "line_number": 12, "req_id": "SRS-005", "context": "// @req SRS-005 Alarm evaluation every 1 second", "file_kind": "source"},
    {"file_path": "src/alarm/alarm_iec60601.c", "line_number": 8, "req_id": "SRS-006", "context": "// @req SRS-006 IEC 60601-1-8 alarm behavior", "file_kind": "source"},
    {"file_path": "src/power/power_mgmt.c", "line_number": 27, "req_id": "SRS-007", "context": "// @req SRS-007 BQ25895 SOC monitoring and graceful shutdown", "file_kind": "source"},
    {"file_path": "src/fhir/fhir_client.c", "line_number": 15, "req_id": "SRS-008", "context": "// @req SRS-008 FHIR R4 Observation POST with mTLS", "file_kind": "source"},
    {"file_path": "src/trend/trend_storage.c", "line_number": 9, "req_id": "SRS-009", "context": "// @req SRS-009 Circular buffer 24h trend writes", "file_kind": "source"},
    {"file_path": "src/trend/trend_display.c", "line_number": 22, "req_id": "SRS-010", "context": "// @req SRS-010 Trend time-series plot rendering", "file_kind": "source"},
    {"file_path": "src/safety/watchdog.c", "line_number": 6, "req_id": "SRS-011", "context": "// @req SRS-011 Watchdog supervisor 2x deadline", "file_kind": "source"},
    {"file_path": "src/safety/post.c", "line_number": 10, "req_id": "SRS-012", "context": "// @req SRS-012 Power-on self-test sequence", "file_kind": "source"},
    {"file_path": "src/nibp/nibp_module.c", "line_number": 19, "req_id": "SRS-013", "context": "// @req SRS-013 Oscillometric NIBP per ISO 81060-2", "file_kind": "source"},
    {"file_path": "src/temp/temp_sensor.c", "line_number": 8, "req_id": "SRS-014", "context": "// @req SRS-014 TMP117 temperature reading", "file_kind": "source"},
    {"file_path": "src/fhir/fhir_bulk_export.c", "line_number": 14, "req_id": "SRS-015", "context": "// @req SRS-015 FHIR Bundle bulk export", "file_kind": "source"},
    {"file_path": "src/enclosure/cleanability_spec.c", "line_number": 12, "req_id": "REQ-006", "context": "// @req REQ-006 enclosure cleanability materials and coating selection", "file_kind": "source"},
    {"file_path": "test/test_spo2.py", "line_number": 5, "req_id": "SRS-001", "context": "# @req SRS-001 @test TG-SPO2", "file_kind": "test"},
    {"file_path": "test/test_ecg.py", "line_number": 5, "req_id": "SRS-003", "context": "# @req SRS-003 @test TG-ECG", "file_kind": "test"},
    {"file_path": "test/test_alarm.py", "line_number": 5, "req_id": "SRS-005", "context": "# @req SRS-005 @test TG-ALARM", "file_kind": "test"},
    {"file_path": "test/test_fhir.py", "line_number": 5, "req_id": "SRS-008", "context": "# @req SRS-008 @test TG-FHIR", "file_kind": "test"},
    {"file_path": "test/test_trend.py", "line_number": 5, "req_id": "SRS-009", "context": "# @req SRS-009 @test TG-TREND", "file_kind": "test"},
    {"file_path": "test/test_safety.py", "line_number": 5, "req_id": "SRS-011", "context": "# @req SRS-011 @test TG-SAFE", "file_kind": "test"},
    {"file_path": "test/test_safety.py", "line_number": 6, "req_id": "SRS-012", "context": "# @req SRS-012 @test TG-SAFE", "file_kind": "test"},
    {"file_path": "test/test_cleanability.py", "line_number": 5, "req_id": "REQ-006", "context": "# @req REQ-006 @test TG-CLEAN", "file_kind": "test"},
]


FILE_TO_TEST_FILES: dict[str, list[str]] = {
    "src/spo2/spo2_module.c": ["test/test_spo2.py"],
    "src/spo2/motion_filter.c": ["test/test_spo2.py"],
    "src/ecg/ecg_acquisition.c": ["test/test_ecg.py"],
    "src/ecg/ecg_display.c": ["test/test_ecg.py"],
    "src/alarm/alarm_manager.c": ["test/test_alarm.py"],
    "src/alarm/alarm_iec60601.c": ["test/test_alarm.py"],
    "src/power/power_mgmt.c": ["test/test_safety.py"],
    "src/fhir/fhir_client.c": ["test/test_fhir.py"],
    "src/fhir/fhir_bulk_export.c": ["test/test_fhir.py", "test/test_trend.py"],
    "src/trend/trend_storage.c": ["test/test_trend.py"],
    "src/trend/trend_display.c": ["test/test_trend.py"],
    "src/safety/watchdog.c": ["test/test_safety.py"],
    "src/safety/post.c": ["test/test_safety.py"],
    "src/enclosure/cleanability_spec.c": ["test/test_cleanability.py"],
}


COMMITS: list[dict[str, Any]] = [
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000001", "short_hash": "0f7a3b8", "date": "2026-03-03T10:20:00Z", "message": "Implement SpO2 module"},
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000002", "short_hash": "0f7a3b9", "date": "2026-03-03T11:10:00Z", "message": "Add motion artifact rejection"},
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000003", "short_hash": "0f7a3ba", "date": "2026-03-04T09:40:00Z", "message": "Implement ECG acquisition"},
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000004", "short_hash": "0f7a3bb", "date": "2026-03-04T10:30:00Z", "message": "Render ECG waveform display"},
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000005", "short_hash": "0f7a3bc", "date": "2026-03-05T08:55:00Z", "message": "Implement alarm manager timing"},
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000006", "short_hash": "0f7a3bd", "date": "2026-03-05T09:45:00Z", "message": "Add IEC 60601 alarm behavior"},
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000007", "short_hash": "0f7a3be", "date": "2026-03-05T11:15:00Z", "message": "Add power management and shutdown"},
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000008", "short_hash": "0f7a3bf", "date": "2026-03-06T12:00:00Z", "message": "Implement FHIR Observation client"},
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000009", "short_hash": "0f7a3c0", "date": "2026-03-06T14:20:00Z", "message": "Add trend storage module"},
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000010", "short_hash": "0f7a3c1", "date": "2026-03-06T15:05:00Z", "message": "Implement trend display"},
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000011", "short_hash": "0f7a3c2", "date": "2026-03-07T09:10:00Z", "message": "Add watchdog supervisor"},
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000012", "short_hash": "0f7a3c3", "date": "2026-03-07T10:25:00Z", "message": "Implement POST sequence"},
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000013", "short_hash": "0f7a3c4", "date": "2026-03-07T13:15:00Z", "message": "Implement NIBP module"},
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000014", "short_hash": "0f7a3c5", "date": "2026-03-07T14:05:00Z", "message": "Add temperature sensor module"},
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000015", "short_hash": "0f7a3c6", "date": "2026-03-05T17:10:00Z", "message": "Implement initial FHIR bulk export"},
    {"id": "0f7a3b89c1d44d809d1cf36bb9321af700000016", "short_hash": "0f7a3c7", "date": "2026-03-04T16:45:00Z", "message": "Document enclosure cleanability constraints"},
]


FILE_TO_COMMIT_ID: dict[str, str] = {
    "src/spo2/spo2_module.c": COMMITS[0]["id"],
    "src/spo2/motion_filter.c": COMMITS[1]["id"],
    "src/ecg/ecg_acquisition.c": COMMITS[2]["id"],
    "src/ecg/ecg_display.c": COMMITS[3]["id"],
    "src/alarm/alarm_manager.c": COMMITS[4]["id"],
    "src/alarm/alarm_iec60601.c": COMMITS[5]["id"],
    "src/power/power_mgmt.c": COMMITS[6]["id"],
    "src/fhir/fhir_client.c": COMMITS[7]["id"],
    "src/trend/trend_storage.c": COMMITS[8]["id"],
    "src/trend/trend_display.c": COMMITS[9]["id"],
    "src/safety/watchdog.c": COMMITS[10]["id"],
    "src/safety/post.c": COMMITS[11]["id"],
    "src/nibp/nibp_module.c": COMMITS[12]["id"],
    "src/temp/temp_sensor.c": COMMITS[13]["id"],
    "src/fhir/fhir_bulk_export.c": COMMITS[14]["id"],
    "src/enclosure/cleanability_spec.c": COMMITS[15]["id"],
    "test/test_spo2.py": COMMITS[1]["id"],
    "test/test_ecg.py": COMMITS[3]["id"],
    "test/test_alarm.py": COMMITS[5]["id"],
    "test/test_fhir.py": COMMITS[14]["id"],
    "test/test_trend.py": COMMITS[9]["id"],
    "test/test_safety.py": COMMITS[11]["id"],
    "test/test_cleanability.py": COMMITS[15]["id"],
}


DEMO_DIAGNOSTICS: list[dict[str, Any]] = [
    {"dedupe_key": "demo:soup:zlib:no-eval", "code": 9001, "severity": "warn", "title": "SOUP anomaly evaluation missing", "message": "zlib 1.2.11 has a known anomaly but no completed evaluation.", "source": "fixture", "subject": f"bom-item://{PRODUCT_FULL_IDENTIFIER}/software/{SOUP_BOM_NAME}/zlib@1.2.11"},
    {"dedupe_key": "demo:soup:micro-ecc:unknown-version", "code": 9002, "severity": "warn", "title": "SOUP version unknown", "message": "Micro-ECC is present with version 'unknown', preventing reliable anomaly assessment.", "source": "fixture", "subject": f"bom-item://{PRODUCT_FULL_IDENTIFIER}/software/{SOUP_BOM_NAME}/Micro-ECC@unknown"},
    {"dedupe_key": "demo:req:srs-015:stale-verification", "code": 9003, "severity": "warn", "title": "Verification may be stale", "message": "SRS-015 changed on 2026-03-10 after its latest linked execution on 2026-03-05.", "source": "fixture", "subject": "SRS-015"},
    {"dedupe_key": "demo:bom:si8621:no-test-linkage", "code": 9004, "severity": "warn", "title": "BOM item has no test linkage", "message": "SI8621EC-B-IS carries requirement refs but no declared test refs.", "source": "fixture", "subject": f"bom-item://{PRODUCT_FULL_IDENTIFIER}/hardware/{HARDWARE_BOM_NAME}/SI8621EC-B-IS@-"},
    {"dedupe_key": "demo:req:srs-016:no-test-coverage", "code": 9005, "severity": "warn", "title": "Requirement missing test coverage", "message": "SRS-016 has no linked test groups.", "source": "fixture", "subject": "SRS-016"},
    {"dedupe_key": "demo:req:srs-017:no-test-coverage", "code": 9006, "severity": "warn", "title": "Requirement missing test coverage", "message": "SRS-017 has no linked test groups.", "source": "fixture", "subject": "SRS-017"},
    {"dedupe_key": "demo:req:srs-016:no-implementation-evidence", "code": 9007, "severity": "warn", "title": "Requirement missing implementation evidence", "message": "SRS-016 has no IMPLEMENTED_IN source evidence.", "source": "fixture", "subject": "SRS-016"},
    {"dedupe_key": "demo:req:srs-017:no-implementation-evidence", "code": 9008, "severity": "warn", "title": "Requirement missing implementation evidence", "message": "SRS-017 has no IMPLEMENTED_IN source evidence.", "source": "fixture", "subject": "SRS-017"},
    {"dedupe_key": "demo:unit:1246:atp-failure", "code": 9009, "severity": "err", "title": "Production ATP failure", "message": "UNIT-1246 failed TC-ATP-004 because alarm latency exceeded the 10s requirement window.", "source": "fixture", "subject": "execution://ate-vs200-revc-unit1246-20260317T08:44:00Z"},
    {"dedupe_key": "demo:req:srs-015:text-mismatch", "code": 9010, "severity": "warn", "title": "Requirement text mismatch", "message": "SRS-015 differs between the RTM workbook and SRS design artifact. RTM remains authoritative.", "source": "fixture", "subject": "SRS-015"},
    {"dedupe_key": "demo:req:srs-016:single-source", "code": 9011, "severity": "info", "title": "Requirement asserted by one source only", "message": "SRS-016 is present only in the SRS artifact, with no corroborating RTM assertion.", "source": "fixture", "subject": "SRS-016"},
    {"dedupe_key": "demo:req:srs-017:single-source", "code": 9012, "severity": "info", "title": "Requirement asserted by one source only", "message": "SRS-017 is present only in the SRS artifact, with no corroborating RTM assertion.", "source": "fixture", "subject": "SRS-017"},
    {"dedupe_key": "demo:req:srs-016:missing-rtm", "code": 9013, "severity": "warn", "title": "Requirement missing RTM assertion", "message": "SRS-016 has no RTM workbook assertion even though it exists in the SRS artifact.", "source": "fixture", "subject": "SRS-016"},
    {"dedupe_key": "demo:req:srs-017:missing-rtm", "code": 9014, "severity": "warn", "title": "Requirement missing RTM assertion", "message": "SRS-017 has no RTM workbook assertion even though it exists in the SRS artifact.", "source": "fixture", "subject": "SRS-017"},
]


EXPECTED_DEMO_MOMENTS = {
    "untested_requirements": ["SRS-016", "SRS-017"],
    "unimplemented_requirements": ["SRS-016", "SRS-017"],
    "stale_requirement": "SRS-015",
    "conflicting_requirement": "SRS-015",
    "missing_rtm_requirements": ["SRS-016", "SRS-017"],
    "failed_unit": "UNIT-1246",
    "open_risk": "RSK-010",
    "eol_part": "BSS138LT1G",
    "soup_gap_component": "zlib",
    "unknown_version_component": "Micro-ECC",
}


EXPECTED_PRODUCTION_SERIAL_COUNT = 47


def all_ate_executions() -> list[dict[str, Any]]:
    batch = generate_passing_ate_batch()
    return batch + [ATE_UNIT_1246, ATE_UNIT_1247]
