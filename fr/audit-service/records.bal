// Holds the information needed to form an audit event based on the FHIR AuditEvent resource
// http://hl7.org/fhir/R4/auditevent.html
type InternalAuditEvent record {|
    // Value Set http://hl7.org/fhir/ValueSet/audit-event-type
    string typeCode = "rest";
    // Value Set http://hl7.org/fhir/ValueSet/audit-event-sub-type 
    string subTypeCode;
    // Value Set http://hl7.org/fhir/ValueSet/audit-event-action
    string actionCode;
    // Value Set http://hl7.org/fhir/ValueSet/audit-event-outcome
    string outcomeCode;
    // Free text description of the outcome (e.g., failure reason)
    string outcomeDesc = "";
    string recordedTime;
    // actor involved in the event
    // Value Set http://hl7.org/fhir/ValueSet/participation-role-type
    string agentType;
    string agentName;
    boolean agentIsRequestor;
    // source of the event
    string sourceObserverName;
    // Value Set http://hl7.org/fhir/R4/valueset-audit-source-type.html
    string sourceObserverType;
    // Value Set http://hl7.org/fhir/ValueSet/audit-entity-type
    string entityType;
    // Value Set http://hl7.org/fhir/ValueSet/object-role
    string entityRole;
    // Requested relative path - eg.: "Patient/example/_history/1"
    string entityWhatReference;

    // ATNA ActiveParticipant — required for ITI-20 compliance
    string agentUserId = "";           // @UserID — login name or service identifier
    string agentAltUserId = "";        // @AlternativeUserID — process ID or secondary ID
    int agentNetworkPointType = 2;     // @NetworkAccessPointTypeCode: 1=DNS, 2=IP
    string agentNetworkPointId = "";   // @NetworkAccessPointID — IP or hostname of requestor

    // ATNA PurposeOfUse (optional; included in XML only when non-empty)
    string purposeOfEvent = "";
    string purposeOfEventSystem = "http://terminology.hl7.org/CodeSystem/v3-ActReason";

|};
