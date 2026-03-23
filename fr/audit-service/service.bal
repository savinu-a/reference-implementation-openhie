import ballerina/http;
import ballerinax/health.fhir.r4.international401;
import ballerinax/health.fhir.r4;
import ballerina/io;
import ballerina/log;
import ballerina/cache;
import ballerina/uuid;
import ballerinax/health.fhir.r4.terminology;
import ballerina/task;
import ballerina/file;
import ballerina/tcp;

// in Choreo context, this is expected to be a path in a file mount
configurable string auditLogPath = "/tmp/audit-logs/fhir-audit.log";
// capacity of the cache used to store the failed audit events till they are retried
configurable int cacheCapacity = 1000;
// name of the fhir server. This is used as the source observer name in the FHIR audit event
configurable string fhirServerName = "wso2fhirserver.com";
// agent type of the audit event. This is used as the agent type in the FHIR audit event
configurable string agentType = "humanuser";
// rotate the log file when it exceeds this size in MB (0 disables rotation)
configurable int maxLogFileSizeMB = 10;
// maximum number of rotated log files to keep (.1 through .N)
configurable int maxRotatedFiles = 5;

// ── ATNA Audit Repository (ITI-20 syslog transport) ──────────────────────────
// Leave atnaRepositoryHost empty to disable syslog (default — zero behaviour change)
configurable string  atnaRepositoryHost   = "";        // syslog server host
configurable int     atnaRepositoryPort   = 6514;      // 6514 = TLS syslog (RFC 5425)
configurable boolean atnaUseTLS           = true;      // false = plain TCP (isolated nets only)
configurable string  atnaCACert           = "";        // path to CA cert for server verification
configurable string  atnaClientCert       = "";        // path to client cert (mTLS / ITI-19)
configurable string  atnaClientKey        = "";        // path to client key  (mTLS / ITI-19)

// ── ATNA Audit Source identification ─────────────────────────────────────────
configurable string atnaAuditSourceId    = "FhirAuditService"; // AuditSourceID
configurable string atnaEnterpriseSiteId = "";                  // AuditEnterpriseSiteID
configurable string atnaSourceHostname   = "localhost";         // syslog HOSTNAME field

// This creates a new cache with the advanced configuration.
final cache:Cache cache = new ({
    capacity: cacheCapacity
});

// Retry failed audit events
class RetryFailedAuditEvents {

    *task:Job;

    public function init() {
        log:printDebug("Initialized the `retry failed audit events` task.");
    }

    // Executes this function when the scheduled trigger fires.
    public function execute() {
        int i = 0;
        if cache.size() > 0 {
            log:printDebug("Retrying to write failed audit events to the log file.", numberOfFailedAuditEvents = cache.size());
        }
        while i < cache.size() {
            // retry to write to the audit log file
            international401:AuditEvent|error auditEvent = cache.get(cache.keys()[i]).ensureType();
            if (auditEvent is international401:AuditEvent) {
                io:Error? result = io:fileWriteLines(auditLogPath, [auditEvent.toJsonString()], option = io:APPEND);
                if !(result is io:Error) {
                    // if retrying is successful, remove from the cache
                    check cache.invalidate(cache.keys()[i]);
                    log:printDebug("Successfully wrote the audit event to the log file.", id = auditEvent.id);
                    // ITI-20: forward to ATNA Audit Repository via RFC 5425 TLS syslog
                    string atnaXml = toAtnaXml(auditEvent);
                    string syslogFrame = buildRfc5424Message(atnaXml, auditEvent.recorded.toString(), auditEvent.outcome ?: "0");
                    sendToAtnaRepository(syslogFrame);
                } else {
                    i += 1;
                    log:printDebug("Failed to retry writing the audit event to the log file. Retrying...", id = auditEvent.id, 'error = result);
                }
            }

        } on fail var e {
            // keep retrying
            log:printDebug("Failed to retry writing the audit event to the log file. Retrying...", e);
        }
    }
}

// Returns log files ordered newest to oldest: [fhir-audit.log, fhir-audit.log.1, ...]
// Only includes files that exist on disk.
isolated function getLogFiles() returns string[] {
    string[] files = [];
    boolean|file:Error exists = file:test(auditLogPath, file:EXISTS);
    if exists is boolean && exists {
        files.push(auditLogPath);
    }
    foreach int i in 1 ... maxRotatedFiles {
        string rotated = auditLogPath + "." + i.toString();
        boolean|file:Error rotatedExists = file:test(rotated, file:EXISTS);
        if rotatedExists is boolean && rotatedExists {
            files.push(rotated);
        }
    }
    return files;
}

// Rotates log files: deletes oldest, shifts .N-1->.N, ..., .1->.2, current->.1
isolated function rotateLogFile() {
    string oldest = auditLogPath + "." + maxRotatedFiles.toString();
    boolean|file:Error oldestExists = file:test(oldest, file:EXISTS);
    if oldestExists is boolean && oldestExists {
        do {
            check file:remove(oldest);
        } on fail error e {
            log:printWarn("Failed to remove oldest rotated log file.", 'error = e, path = oldest);
        }
    }
    int i = maxRotatedFiles - 1;
    while i >= 1 {
        string src = auditLogPath + "." + i.toString();
        string dst = auditLogPath + "." + (i + 1).toString();
        boolean|file:Error srcExists = file:test(src, file:EXISTS);
        if srcExists is boolean && srcExists {
            do {
                check file:rename(src, dst);
            } on fail error e {
                log:printWarn("Failed to rename rotated log file.", 'error = e, src = src, dst = dst);
            }
        }
        i -= 1;
    }
    boolean|file:Error currentExists = file:test(auditLogPath, file:EXISTS);
    if currentExists is boolean && currentExists {
        do {
            check file:rename(auditLogPath, auditLogPath + ".1");
        } on fail error e {
            log:printWarn("Failed to rotate current log file.", 'error = e);
        }
    }
    log:printInfo("Audit log rotated.", maxRotatedFiles = maxRotatedFiles);
}

// Returns the `recorded` timestamp of the first non-empty parseable line, or "" if none.
isolated function getFirstTimestamp(string[] lines) returns string {
    foreach string line in lines {
        if line.trim().length() == 0 {
            continue;
        }
        json|error parsed = line.fromJsonString();
        if parsed is json {
            json|error ts = parsed.recorded;
            if ts is json {
                return ts.toString();
            }
        }
        break;
    }
    return "";
}

// Returns the `recorded` timestamp of the last non-empty parseable line, or "" if none.
isolated function getLastTimestamp(string[] lines) returns string {
    int i = lines.length() - 1;
    while i >= 0 {
        string line = lines[i];
        if line.trim().length() > 0 {
            json|error parsed = line.fromJsonString();
            if parsed is json {
                json|error ts = parsed.recorded;
                if ts is json {
                    return ts.toString();
                }
            }
        }
        i -= 1;
    }
    return "";
}

configurable int port = 9096;

service / on new http:Listener(port) {

    function init() returns error? {
        // this is an internal task, hence the interval does not needs to be a configurable. 
        _ = check task:scheduleJobRecurByFrequency(
                            new RetryFailedAuditEvents(), 30);
        log:printInfo("FHIR Audit Service is started...", port = port);
    }

    // GET /audits - Read audit events from the log file
    isolated resource function get audits(http:Request req, string? action, string? subtype,
            string? since, string? before, int 'limit = 50, int offset = 0, string sortOrder = "desc")
            returns json|http:STATUS_INTERNAL_SERVER_ERROR {

        int effectiveLimit = 'limit < 1 ? 50 : 'limit;
        int startIdx = offset < 0 ? 0 : offset;
        int needed = startIdx + effectiveLimit;

        // Get log files: index 0 = newest. For asc, reverse to oldest-first.
        string[] logFiles = getLogFiles();
        if sortOrder == "asc" {
            logFiles = logFiles.reverse();
        }

        json[] allMatching = [];

        foreach string logFile in logFiles {
            // Early exit: we already have enough matching records
            if allMatching.length() >= needed {
                break;
            }

            string[]|io:Error linesResult = io:fileReadLines(logFile);
            if linesResult is io:Error {
                string errMsg = linesResult.message();
                if errMsg.includes("no such file") || errMsg.includes("does not exist") || errMsg.includes("cannot find") || errMsg.includes("FileNotFound") {
                    continue;
                }
                log:printError("Failed to read audit log file.", 'error = linesResult, path = logFile);
                return http:STATUS_INTERNAL_SERVER_ERROR;
            }
            string[] lines = linesResult;

            // Skip this file entirely if its time range doesn't overlap the query window
            if since is string || before is string {
                string fileStart = getFirstTimestamp(lines);
                string fileEnd = getLastTimestamp(lines);
                if fileStart != "" && before is string && fileStart > before {
                    // Entire file is newer than 'before' — skip
                    continue;
                }
                if fileEnd != "" && since is string && fileEnd < since {
                    // Entire file is older than 'since' — for desc, no older file can help either
                    if sortOrder != "asc" {
                        break;
                    }
                    continue;
                }
            }

            // For desc: process lines newest-first within this file
            string[] orderedLines = sortOrder == "asc" ? lines : lines.reverse();

            foreach string line in orderedLines {
                if allMatching.length() >= needed {
                    break;
                }
                if line.trim().length() == 0 {
                    continue;
                }
                json|error parsed = line.fromJsonString();
                if parsed is json {
                    // Skip framework-generated audit events
                    json|error sourceObserver = parsed.'source.observer.display;
                    if sourceObserver is json && sourceObserver.toString() == fhirServerName {
                        continue;
                    }

                    // Apply optional filters
                    boolean include = true;
                    if action is string {
                        json|error eventAction = parsed.action;
                        if eventAction is json {
                            include = eventAction.toString() == action;
                        }
                    }
                    if include && subtype is string {
                        json|error subtypeArr = parsed.subtype;
                        if subtypeArr is json {
                            include = subtypeArr.toString().includes(subtype);
                        }
                    }
                    if include && (since is string || before is string) {
                        json|error recordedTime = parsed.recorded;
                        if recordedTime is json {
                            string recorded = recordedTime.toString();
                            if since is string {
                                include = recorded > since;
                            }
                            if include && before is string {
                                include = recorded < before;
                            }
                        }
                    }
                    if include {
                        allMatching.push(parsed);
                    }
                }
            }
        }

        // Apply offset/limit — records are already in the correct sort order
        json[] paginated = [];
        int idx = startIdx;
        while idx < needed && idx < allMatching.length() {
            paginated.push(allMatching[idx]);
            idx += 1;
        }
        return paginated;
    }

    resource function post audits(international401:AuditEvent audit) returns international401:AuditEvent|http:STATUS_ACCEPTED|http:STATUS_INTERNAL_SERVER_ERROR {
        international401:AuditEvent auditEvent = audit;
        if !(auditEvent.id is string) || auditEvent.id == "" {
            auditEvent.id = uuid:createType1AsString();
        }
        // Rotate log file if it exceeds the configured size limit
        if maxLogFileSizeMB > 0 {
            file:MetaData|file:Error meta = file:getMetaData(auditLogPath);
            if meta is file:MetaData && meta.size > maxLogFileSizeMB * 1024 * 1024 {
                rotateLogFile();
            }
        }
        io:Error? result = io:fileWriteLines(auditLogPath, [auditEvent.toJsonString()], option = io:APPEND);
        if result is io:Error {
            // keep track of failed audit events in an inmemory buffer and retry to write
            log:printWarn("Failed to write the audit event to the log file. Trying to put to a cache and retry later.", result, id = auditEvent.id, auditEvent = auditEvent.toJson());
            do {
                check cache.put(check auditEvent.id.ensureType(), auditEvent);
                return http:STATUS_ACCEPTED;
            } on fail error e {
                log:printError("[Critical] Failed to write to the log file and failed in adding it to the cache. Audit event will be lost.", 'error = e,
                auditEvent = auditEvent.toJson());
                return http:STATUS_INTERNAL_SERVER_ERROR;
            }
        } else {
            log:printDebug("Successfully wrote the audit event to the log file.", id = auditEvent.id);
            // ITI-20: forward to ATNA Audit Repository via RFC 5425 TLS syslog
            string atnaXml = toAtnaXml(auditEvent);
            string syslogFrame = buildRfc5424Message(atnaXml, auditEvent.recorded.toString(), auditEvent.outcome ?: "0");
            sendToAtnaRepository(syslogFrame);
        }
        return auditEvent;
    }
}

isolated function toFhirAuditEvent(InternalAuditEvent internalAuditEvent) returns international401:AuditEvent => {
    id: uuid:createType1AsString(),
    'type: getCoding("http://terminology.hl7.org/CodeSystem/audit-event-type", internalAuditEvent.typeCode),
    subtype: [getCoding("http://hl7.org/fhir/restful-interaction", internalAuditEvent.subTypeCode)],
    action: internalAuditEvent.actionCode,
    outcome: internalAuditEvent.outcomeCode,
    outcomeDesc: internalAuditEvent.outcomeDesc != "" ? internalAuditEvent.outcomeDesc : (),
    recorded: internalAuditEvent.recordedTime,
    agent: [getAgent(internalAuditEvent.agentType, internalAuditEvent.agentName, internalAuditEvent.agentIsRequestor,
        internalAuditEvent.agentUserId, internalAuditEvent.agentAltUserId,
        internalAuditEvent.agentNetworkPointType, internalAuditEvent.agentNetworkPointId)],
    entity: [getEntity(internalAuditEvent.entityType, internalAuditEvent.entityRole, internalAuditEvent.entityWhatReference)],
    purposeOfEvent: internalAuditEvent.purposeOfEvent != "" ? [{
        coding: [getCoding(internalAuditEvent.purposeOfEventSystem, internalAuditEvent.purposeOfEvent)]
    }] : (),
    'source: {
        observer: {
            display: internalAuditEvent.sourceObserverName == "" ? fhirServerName : internalAuditEvent.sourceObserverName
        },
        'type: [getCoding("http://terminology.hl7.org/CodeSystem/security-source-type", internalAuditEvent.sourceObserverType)]
    }
};

isolated function getCoding(string system, string code) returns r4:Coding {
    r4:Coding|r4:FHIRError fhirCode = terminology:createCoding(system, code);
    if (fhirCode is r4:FHIRError) {
        // means the code system is not available in the terminology server
        // skip the error and mark the value as unknown.
        return {
            system: system,
            code: code,
            display: "Unknown"
        };
    }
    return fhirCode;
};

isolated function getAgent(string 'type, string name, boolean isRequestor,
        string userId, string altUserId, int networkPointType, string networkPointId)
        returns international401:AuditEventAgent {
    international401:AuditEventAgent agent = {
        'type: {
            coding:
            [getCoding("http://terminology.hl7.org/CodeSystem/extra-security-role-type", 'type == "" ? agentType : 'type)]
        },
        who: {
            display: name,
            identifier: userId != "" ? {'value: userId, system: altUserId} : ()
        },
        requestor: isRequestor,
        network: networkPointId != "" ? {address: networkPointId, 'type: networkPointType.toString()} : ()
    };
    return agent;
};

isolated function xmlEscape(string val) returns string {
    string result = val;
    result = re `&`.replaceAll(result, "&amp;");
    result = re `<`.replaceAll(result, "&lt;");
    result = re `>`.replaceAll(result, "&gt;");
    result = re `"`.replaceAll(result, "&quot;");
    result = re `'`.replaceAll(result, "&apos;");
    return result;
}

// Generates a DICOM PS3.15 Annex A.5 XML audit message from a FHIR AuditEvent.
// This is the payload required by IHE ITI-20 (Record Audit Event).
isolated function toAtnaXml(international401:AuditEvent auditEvent) returns string {
    json auditJson = auditEvent.toJson();

    // ── EventIdentification ───────────────────────────────────────────────────
    string eventAction = "E";
    json|error jeAction = auditJson.action;
    if jeAction is json && jeAction.toString() != "null" { eventAction = xmlEscape(jeAction.toString()); }

    string eventDateTime = "";
    json|error jeRecorded = auditJson.recorded;
    if jeRecorded is json && jeRecorded.toString() != "null" { eventDateTime = xmlEscape(jeRecorded.toString()); }

    string eventOutcome = "0";
    json|error jeOutcome = auditJson.outcome;
    if jeOutcome is json && jeOutcome.toString() != "null" { eventOutcome = xmlEscape(jeOutcome.toString()); }

    // EventID — from AuditEvent.type (a Coding: code, system, display)
    string eventIdCode = ""; string eventIdText = ""; string eventIdSystem = "";
    json|error jeType = auditJson.'type;
    if jeType is json {
        json|error jeCode = jeType.code;
        if jeCode is json && jeCode.toString() != "null" { eventIdCode = xmlEscape(jeCode.toString()); }
        json|error jeSys = jeType.system;
        if jeSys is json && jeSys.toString() != "null" { eventIdSystem = xmlEscape(jeSys.toString()); }
        json|error jeDisp = jeType.display;
        eventIdText = (jeDisp is json && jeDisp.toString() != "null") ? xmlEscape(jeDisp.toString()) : eventIdCode;
    }

    // EventTypeCode — from AuditEvent.subtype[0] (a Coding)
    string evtTypeCode = ""; string evtTypeText = ""; string evtTypeSystem = "";
    json|error jeSubtypes = auditJson.subtype;
    if jeSubtypes is json[] && jeSubtypes.length() > 0 {
        json sub0 = jeSubtypes[0];
        json|error jeStCode = sub0.code;
        if jeStCode is json && jeStCode.toString() != "null" { evtTypeCode = xmlEscape(jeStCode.toString()); }
        json|error jeStSys = sub0.system;
        if jeStSys is json && jeStSys.toString() != "null" { evtTypeSystem = xmlEscape(jeStSys.toString()); }
        json|error jeStDisp = sub0.display;
        evtTypeText = (jeStDisp is json && jeStDisp.toString() != "null") ? xmlEscape(jeStDisp.toString()) : evtTypeCode;
    }

    // PurposeOfUse — from AuditEvent.purposeOfEvent[0].coding[0] (optional)
    string purposeXml = "";
    json|error jePurpose = auditJson.purposeOfEvent;
    if jePurpose is json[] && jePurpose.length() > 0 {
        json|error jePCoding = jePurpose[0].coding;
        if jePCoding is json[] && jePCoding.length() > 0 {
            json pc0 = jePCoding[0];
            string pCode = ""; string pText = ""; string pSystem = "";
            json|error jePCode = pc0.code;
            if jePCode is json && jePCode.toString() != "null" { pCode = xmlEscape(jePCode.toString()); }
            json|error jePSys = pc0.system;
            if jePSys is json && jePSys.toString() != "null" { pSystem = xmlEscape(jePSys.toString()); }
            json|error jePDisp = pc0.display;
            pText = (jePDisp is json && jePDisp.toString() != "null") ? xmlEscape(jePDisp.toString()) : pCode;
            if pCode != "" {
                purposeXml = string `    <PurposeOfUse csd-code="${pCode}" originalText="${pText}" codeSystemName="${pSystem}"/>` + "\n";
            }
        }
    }

    // ── ActiveParticipant ─────────────────────────────────────────────────────
    string agentXml = "";
    json|error jeAgents = auditJson.agent;
    if jeAgents is json[] {
        foreach json agentJ in jeAgents {
            string userId = ""; string altUserId = ""; string userName = "";
            string requestor = "false"; string netType = "2"; string netAddr = "";
            string roleCode = ""; string roleText = ""; string roleSystem = "";

            // who.display → UserName; who.identifier.value → UserID (preferred)
            json|error jeWho = agentJ.who;
            if jeWho is json {
                json|error jeWDisp = jeWho.display;
                if jeWDisp is json && jeWDisp.toString() != "null" {
                    userName = xmlEscape(jeWDisp.toString());
                    userId = userName; // fallback if no identifier
                }
                json|error jeIdent = jeWho.identifier;
                if jeIdent is json {
                    json|error jeVal = jeIdent.value;
                    if jeVal is json && jeVal.toString() != "null" { userId = xmlEscape(jeVal.toString()); }
                    json|error jeISys = jeIdent.system;
                    if jeISys is json && jeISys.toString() != "null" { altUserId = xmlEscape(jeISys.toString()); }
                }
            }

            json|error jeReq = agentJ.requestor;
            if jeReq is json { requestor = jeReq.toString() == "true" ? "true" : "false"; }

            // network.address → NetworkAccessPointID, network.type → NetworkAccessPointTypeCode
            json|error jeNet = agentJ.network;
            if jeNet is json {
                json|error jeNetType = jeNet.'type;
                if jeNetType is json && jeNetType.toString() != "null" { netType = xmlEscape(jeNetType.toString()); }
                json|error jeNetAddr = jeNet.address;
                if jeNetAddr is json && jeNetAddr.toString() != "null" { netAddr = xmlEscape(jeNetAddr.toString()); }
            }

            // agent.type.coding[0] → RoleIDCode
            json|error jeAgType = agentJ.'type;
            if jeAgType is json {
                json|error jeCoding = jeAgType.coding;
                if jeCoding is json[] && jeCoding.length() > 0 {
                    json c0 = jeCoding[0];
                    json|error jeCCode = c0.code;
                    if jeCCode is json && jeCCode.toString() != "null" { roleCode = xmlEscape(jeCCode.toString()); }
                    json|error jeCSys = c0.system;
                    if jeCSys is json && jeCSys.toString() != "null" { roleSystem = xmlEscape(jeCSys.toString()); }
                    json|error jeCDisp = c0.display;
                    roleText = (jeCDisp is json && jeCDisp.toString() != "null") ? xmlEscape(jeCDisp.toString()) : roleCode;
                }
            }

            agentXml += string `  <ActiveParticipant UserID="${userId}" AlternativeUserID="${altUserId}" UserName="${userName}" UserIsRequestor="${requestor}" NetworkAccessPointTypeCode="${netType}" NetworkAccessPointID="${netAddr}">
    <RoleIDCode csd-code="${roleCode}" originalText="${roleText}" codeSystemName="${roleSystem}"/>
  </ActiveParticipant>` + "\n";
        }
    }

    // ── AuditSourceIdentification ─────────────────────────────────────────────
    string srcTypeCode = "4"; string srcTypeText = "Application Server Process or Thread"; string srcTypeSystem = "DCM";
    json|error jeSrc = auditJson.'source;
    if jeSrc is json {
        json|error jeSrcTypes = jeSrc.'type;
        if jeSrcTypes is json[] && jeSrcTypes.length() > 0 {
            json st0 = jeSrcTypes[0];
            json|error jeStCode = st0.code;
            if jeStCode is json && jeStCode.toString() != "null" { srcTypeCode = xmlEscape(jeStCode.toString()); }
            json|error jeStSys = st0.system;
            if jeStSys is json && jeStSys.toString() != "null" { srcTypeSystem = xmlEscape(jeStSys.toString()); }
            json|error jeStDisp = st0.display;
            if jeStDisp is json && jeStDisp.toString() != "null" { srcTypeText = xmlEscape(jeStDisp.toString()); }
        }
    }
    string sourceId = xmlEscape(atnaAuditSourceId);
    string enterpriseAttr = atnaEnterpriseSiteId != "" ? string ` AuditEnterpriseSiteID="${xmlEscape(atnaEnterpriseSiteId)}"` : "";

    // ── ParticipantObjectIdentification ───────────────────────────────────────
    string entityXml = "";
    json|error jeEntities = auditJson.entity;
    if jeEntities is json[] {
        foreach json entityJ in jeEntities {
            string objId = ""; string objTypeCode = ""; string objRoleCode = "";

            json|error jeWhat = entityJ.what;
            if jeWhat is json {
                json|error jeRef = jeWhat.reference;
                if jeRef is json && jeRef.toString() != "null" {
                    objId = xmlEscape(jeRef.toString());
                } else {
                    json|error jeWDisp = jeWhat.display;
                    if jeWDisp is json && jeWDisp.toString() != "null" { objId = xmlEscape(jeWDisp.toString()); }
                }
            }

            json|error jeEType = entityJ.'type;
            if jeEType is json {
                json|error jeECode = jeEType.code;
                if jeECode is json && jeECode.toString() != "null" { objTypeCode = xmlEscape(jeECode.toString()); }
            }

            json|error jeERole = entityJ.role;
            if jeERole is json {
                json|error jeECode = jeERole.code;
                if jeECode is json && jeECode.toString() != "null" { objRoleCode = xmlEscape(jeECode.toString()); }
            }

            entityXml += string `  <ParticipantObjectIdentification ParticipantObjectID="${objId}" ParticipantObjectTypeCode="${objTypeCode}" ParticipantObjectTypeCodeRole="${objRoleCode}">
    <ParticipantObjectIDTypeCode csd-code="2" originalText="Patient Number" codeSystemName="RFC-3881"/>
  </ParticipantObjectIdentification>` + "\n";
        }
    }

    // ── Assemble final XML ────────────────────────────────────────────────────
    return string `<?xml version="1.0" encoding="UTF-8"?>
<AuditMessage>
  <EventIdentification EventActionCode="${eventAction}" EventDateTime="${eventDateTime}" EventOutcomeIndicator="${eventOutcome}">
    <EventID csd-code="${eventIdCode}" originalText="${eventIdText}" codeSystemName="${eventIdSystem}"/>
    <EventTypeCode csd-code="${evtTypeCode}" originalText="${evtTypeText}" codeSystemName="${evtTypeSystem}"/>
${purposeXml}  </EventIdentification>
${agentXml}  <AuditSourceIdentification AuditSourceID="${sourceId}"${enterpriseAttr}>
    <AuditSourceTypeCode csd-code="${srcTypeCode}" originalText="${srcTypeText}" codeSystemName="${srcTypeSystem}"/>
  </AuditSourceIdentification>
${entityXml}</AuditMessage>`;
}

isolated function buildRfc5424Message(string xmlPayload, string timestamp, string outcome) returns string {
    // Severity: 5=Notice (success), 4=Warning (minor failure), 3=Error (serious/major)
    int severity = outcome == "0" ? 5 : (outcome == "4" ? 4 : 3);
    int pri = (10 * 8) + severity; // facility 10 = security/authorization messages

    string ts = timestamp == "" ? "-" : timestamp;

    // RFC 5424 syslog message (no BOM per spec)
    string syslogMsg = string `<${pri}>1 ${ts} ${xmlEscape(atnaSourceHostname)} FhirAuditService - IHE+RFC-3881 - ${xmlPayload}`;

    // RFC 5425 octet-count framing: "{byte-length} {syslog-msg}"
    int msgLen = syslogMsg.toBytes().length();
    return string `${msgLen} ${syslogMsg}`;
}

function sendToAtnaRepository(string syslogFrame) {
    if atnaRepositoryHost == "" {
        return; // syslog disabled — no-op
    }
    do {
        tcp:Client syslogClient;
        if atnaUseTLS {
            // atnaCACert="" uses the default trust store; atnaClientCert/Key reserved for when
            // ballerina/tcp adds mTLS (ClientSecureSocket.key) support
            tcp:ClientSecureSocket secureSocket = atnaCACert != "" ? {cert: atnaCACert} : {};
            syslogClient = check new (atnaRepositoryHost, atnaRepositoryPort, secureSocket = secureSocket);
        } else {
            syslogClient = check new (atnaRepositoryHost, atnaRepositoryPort);
        }
        check syslogClient->writeBytes(syslogFrame.toBytes());
        check syslogClient->close();
        log:printDebug("Sent audit event to ATNA repository.", host = atnaRepositoryHost, port = atnaRepositoryPort);
    } on fail error e {
        log:printWarn("Failed to send audit event to ATNA repository.", 'error = e,
            host = atnaRepositoryHost, port = atnaRepositoryPort);
    }
}

isolated function getEntity(string 'type, string role, string whatReference) returns international401:AuditEventEntity {
    international401:AuditEventEntity entity = {
        'type: getCoding("http://terminology.hl7.org/CodeSystem/audit-entity-type", 'type),
        role: getCoding("http://terminology.hl7.org/CodeSystem/object-role", role),
        what: {
            reference: whatReference
        }
    };
    return entity;
};
