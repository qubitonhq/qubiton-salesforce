/**
 * Runs QubitOn checks on Accounts asynchronously (callouts are not allowed during a save).
 * Up to 13 callouts per account; processes PER_JOB accounts per job and chains the rest,
 * staying under Salesforce's 100-callout / 120-second limits.
 *
 * Enrichment: business classification plus the certification lookup. When the QubitOn Settings custom setting
 * Use_Data_Lookup__c is on, the QubitOn data lookup (enterprise plans) runs first instead; when it answers those two
 * calls are skipped, and when it is not entitled (HTTP 403) or fails they run as usual.
 */
public with sharing class QubitOnAccountScreening implements Queueable, Database.AllowsCallouts {
    /** Callout time, not the callout count, is the limit (120 s per job). Without data lookup a 4-account job took 4 to
     *  61 s live (12 calls per account). Data lookup takes 5 to 13 s per account (timeout 30 s) and replaces two ~1 s
     *  calls, so with it on 3 accounts per job keep the slow case (3 x 13 s on top of ~46 s of other calls) inside. */
    @TestVisible private static final Integer PER_JOB = 4, PER_JOB_DATA_LOOKUP = 3;
    @TestVisible static Integer perJob() { return useDataLookup() ? PER_JOB_DATA_LOOKUP : PER_JOB; }

    /** QubitOn Settings (hierarchy custom setting) Use_Data_Lookup__c; off when the setting has no record. */
    public static Boolean useDataLookup() {
        QubitOn_Settings__c st = QubitOn_Settings__c.getInstance();
        return st != null && st.Use_Data_Lookup__c == true;
    }
    private final List<Id> accountIds;

    public QubitOnAccountScreening(List<Id> accountIds) { this.accountIds = accountIds; }

    public static void enqueue(Set<Id> ids) {
        if (ids.isEmpty() || Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) return;
        System.enqueueJob(new QubitOnAccountScreening(new List<Id>(ids)));
    }

    public void execute(QueueableContext ctx) {
        List<Id> now = new List<Id>(), later = new List<Id>();
        Integer max = perJob();
        for (Id i : accountIds) { if (now.size() < max) now.add(i); else later.add(i); }
        String soql = 'SELECT Id, Name, Phone, BillingStreet, BillingCity, BillingState, BillingPostalCode, BillingCountry, '
            + 'Website, NumberOfEmployees, AnnualRevenue, TickerSymbol, '
            + 'QubitOn_Tax_ID__c, QubitOn_Tax_ID_Type__c' + (HAS_CODES ? ', BillingStateCode, BillingCountryCode' : '')
            + (HAS_TRADESTYLE ? ', Tradestyle' : '')
            + ' FROM Account WHERE Id IN :now';
        List<Account> accts = (List<Account>) Database.query(soql);
        for (Account a : accts) screen(a);
        QubitOnTriggerGuard.skip = true;
        update accts;
        QubitOnTriggerGuard.skip = false;
        if (!Test.isRunningTest()) QubitOnOwnershipRecheck.schedule(pendingOwnership, 1);
        if (!later.isEmpty() && !Test.isRunningTest()) System.enqueueJob(new QubitOnAccountScreening(later));
    }

    /** Firmographics from the classification response (present only with the firmographics entitlement). */
    @TestVisible static void applyFirmographics(Account a, Map<String, Object> r) {
        Decimal emp = num(r.get('employeesTotal')), rev = num(r.get('salesVolume'));
        String web = (String) r.get('website'), ticker = (String) r.get('tickerSymbol'), exch = (String) r.get('stockExchange');
        a.QubitOn_Employees__c = emp;
        a.QubitOn_Revenue__c = rev;
        a.QubitOn_Website__c = web == null ? null : web.left(255);
        a.QubitOn_Ticker__c = String.isBlank(ticker) ? null : ((String.isBlank(exch) ? '' : exch + ': ') + ticker).left(40);
        a.QubitOn_Data_Source__c = ((String) r.get('dataSource'))?.left(50);
        a.QubitOn_Record_ID__c = ((String) r.get('matchedRecordId'))?.left(50);
        a.QubitOn_Out_of_Business__c = r.get('isOutOfBusiness') == true;
        List<String> flags = new List<String>();
        if (r.get('isMinorityOwned') == true) flags.add('Minority-owned');
        if (r.get('isWomenOwned') == true) flags.add('Women-owned');
        if (r.get('isVeteranOwned') == true) flags.add('Veteran-owned');
        if (r.get('isSmallBusiness') == true) flags.add('Small business');
        if (r.get('isNonProfit') == true) flags.add('Nonprofit');
        if (r.get('isPublic') == true) flags.add('Public company');
        a.QubitOn_Diversity__c = flags.isEmpty() ? null : String.join(flags, '; ');
        // Standard fields: fill only when blank, never overwrite what users entered.
        if (String.isBlank(a.Website) && String.isNotBlank(web)) a.Website = web.left(255);
        if (a.NumberOfEmployees == null && emp != null && emp <= 99999999) a.NumberOfEmployees = emp.intValue();
        // Without an employee count from the API, the Account's own count (user-entered or filled earlier) is the denominator.
        Decimal denom = emp != null ? emp : (a.NumberOfEmployees == null ? null : Decimal.valueOf(a.NumberOfEmployees));
        if (a.AnnualRevenue == null && plausibleRevenue(rev, denom)) a.AnnualRevenue = rev;
        if (String.isBlank(a.TickerSymbol) && String.isNotBlank(ticker)) a.TickerSymbol = ticker.left(20);
    }

    /** salesVolume is documented as whole US dollars, but some source records still carry thousands or millions
     *  (live 2026-11-16: Microsoft 118200 for 223000 employees, data/api#8611; the rest is fixed by the golden full
     *  sync). Until every record is in dollars, the standard Annual Revenue field is filled only when revenue per
     *  employee is at least this many dollars. QubitOn_Revenue__c always keeps the value as reported. */
    @TestVisible static final Decimal MIN_REVENUE_PER_EMPLOYEE = 10000;
    /** Without an employee count the per-employee test cannot run, so revenue must be at least this much. Live
     *  2026-11-16: data lookup sent no employees for Microsoft (118200) or Apple (179000), both in millions. */
    @TestVisible static final Decimal MIN_REVENUE_WITHOUT_EMPLOYEES = 1000000;
    @TestVisible static Boolean plausibleRevenue(Decimal rev, Decimal emp) {
        if (rev == null) return false;
        return emp == null ? rev >= MIN_REVENUE_WITHOUT_EMPLOYEES : rev / emp >= MIN_REVENUE_PER_EMPLOYEE;
    }

    /** Joins whole items with "; " up to max characters; never cuts a code in half. */
    @TestVisible static String joinLimited(List<String> items, Integer max) {
        String out = '';
        for (String s : items) {
            String next = out == '' ? s : out + '; ' + s;
            if (next.length() > max) { if (out == '') out = s.left(max); break; }
            out = next;
        }
        return out == '' ? null : out;
    }

    /** One industry code from the classification answer. rank, role and confidence are null on older answers. */
    @TestVisible class IndustryCode implements Comparable {
        public String code, description, role, confidence; public Integer rank, seq;
        public Integer compareTo(Object o) {
            IndustryCode b = (IndustryCode) o;
            // Ranked codes first, best rank first; unranked codes keep the order the API sent them in.
            Integer ra = rank == null ? 2147483647 : rank, rb = b.rank == null ? 2147483647 : b.rank;
            if (ra != rb) return ra < rb ? -1 : 1;
            return seq == b.seq ? 0 : (seq < b.seq ? -1 : 1);
        }
        public String label() { return code + (String.isBlank(description) ? '' : ' ' + description); }
        /** "5045 Computers (P, High)": P = primary, S = secondary; the tag is left out when the API sends neither. */
        public String listItem() {
            String r = role == null ? null : (role.equalsIgnoreCase('primary') ? 'P' : 'S');
            String c = confidenceWord(confidence, false);
            if (r == null && c == null) return label();
            return label() + ' (' + (r == null ? c : (c == null ? r : r + ', ' + c)) + ')';
        }
        public Boolean isPrimary() {
            // The API marks at most one primary per type, and only when its confidence is Medium or High.
            // Checking both keeps a Low code out of the primary field even if the API ever sends that pair.
            String c = confidenceWord(confidence, false);
            return role != null && role.equalsIgnoreCase('primary') && (c == 'High' || c == 'Medium');
        }
    }

    /** Fills the primary NAICS/SIC fields and the ranked code lists. 8-digit SIC codes are dropped (their 4-digit
     *  parent is listed). Missing rank, role or confidence (older answers, the non-golden path): API order, no tag,
     *  no primary. */
    @TestVisible static void applyIndustryCodes(Account a, Object raw) {
        List<IndustryCode> sic = new List<IndustryCode>(), naics = new List<IndustryCode>();
        if (raw instanceof List<Object>) {
            Integer seq = 0;
            for (Object o : (List<Object>) raw) {
                if (!(o instanceof Map<String, Object>)) continue;
                Map<String, Object> m = (Map<String, Object>) o;
                IndustryCode c = new IndustryCode();
                c.code = m.get('industryCodeValue') == null ? null : String.valueOf(m.get('industryCodeValue'));
                if (String.isBlank(c.code)) continue;
                c.description = ((String) m.get('industryCodeDescription'))?.normalizeSpace(); // some descriptions carry a line break
                c.role = (String) m.get('role');
                c.confidence = (String) m.get('confidence');
                c.rank = toInt(m.get('rank'));
                c.seq = seq++;
                String t = (String) m.get('industryCodeType');
                if (t == 'NAICS') naics.add(c);
                else if (t == 'SIC' && c.code.length() == 4) sic.add(c);
            }
        }
        a.QubitOn_SIC_Codes__c = codeList(sic);
        a.QubitOn_NAICS_Codes__c = codeList(naics);
        a.QubitOn_Primary_SIC__c = primaryOf(sic);
        a.QubitOn_Primary_NAICS__c = primaryOf(naics);
    }
    private static Integer toInt(Object o) {
        if (o == null) return null;
        try { return Decimal.valueOf(String.valueOf(o)).intValue(); } catch (Exception e) { return null; }
    }
    private static String codeList(List<IndustryCode> codes) {
        codes.sort();
        List<String> items = new List<String>();
        Set<String> seen = new Set<String>();
        // Data lookup can list one code several times (live: Microsoft SIC 7372 at ranks 2, 3 and 4); keep the best rank.
        for (IndustryCode c : codes) if (seen.add(c.code)) items.add(c.listItem());
        return joinLimited(items, 255);
    }
    private static String primaryOf(List<IndustryCode> sorted) {
        for (IndustryCode c : sorted) if (c.isPrimary()) return c.label().left(255);
        return null;
    }

    /** "High", "Medium" or "Low" in that spelling; "None" only when allowNone. Anything else (absent, unknown) is null. */
    @TestVisible static String confidenceWord(Object v, Boolean allowNone) {
        String s = v == null ? null : String.valueOf(v).trim().toLowerCase();
        if (s == 'high') return 'High';
        if (s == 'medium') return 'Medium';
        if (s == 'low') return 'Low';
        if (s == 'none' && allowNone) return 'None';
        return null;
    }
    private static void addConfidence(List<String> out, String label, Map<String, Object> r) {
        String c = confidenceWord(r.get('matchConfidence'), true);
        if (c != null) out.add(label + ': ' + c);
    }

    /** Maps the data lookup header. Out-of-business status always shows. A Low match (for example the closest company
     *  when the address matched none, AddressNotMatched) may be another company, so its firmographics, industry codes,
     *  certifications, payment methods and risk flags stay blank; so do they when nothing matched. An answer without
     *  matchConfidence (API builds before the confidence scale) counts as a match when it names a QubitOn company. */
    @TestVisible static void applyDataLookup(Account a, Map<String, Object> h) {
        String conf = confidenceWord(h.get('matchConfidence'), false);
        List<String> matchedOn = new List<String>();
        if (h.get('matchedOn') instanceof List<Object>) for (Object o : (List<Object>) h.get('matchedOn')) if (o != null) matchedOn.add(String.valueOf(o));
        String entityId = h.get('qubitOnEntityId') == null ? null : String.valueOf(h.get('qubitOnEntityId'));
        Boolean matched = String.isNotBlank(entityId) && str(h.get('matchConfidence')).toLowerCase() != 'none';
        Boolean usable = matched && conf != 'Low';
        a.QubitOn_Match_Confidence__c = matched ? conf : null;
        a.QubitOn_Matched_On__c = matchedOn.isEmpty() ? null : String.join(matchedOn, ', ').left(255);
        Boolean addrMiss = false;
        for (String o : matchedOn) if (o.equalsIgnoreCase('AddressNotMatched')) addrMiss = true;
        a.QubitOn_Address_Not_Matched__c = addrMiss;
        a.QubitOn_Confidence_Code__c = null; // classification-only scale
        List<Object> urls = h.get('url') instanceof List<Object> ? (List<Object>) h.get('url') : new List<Object>();
        Map<String, Object> firmo = new Map<String, Object>{
            'dataSource' => matched ? 'QubitOn data lookup' : null, 'matchedRecordId' => entityId };
        if (usable) {
            firmo.put('employeesTotal', h.get('employeesTotal'));
            firmo.put('salesVolume', h.get('salesVolume') != null ? h.get('salesVolume') : h.get('annualRevenue'));
            firmo.put('website', urls.isEmpty() || urls[0] == null ? null : String.valueOf(urls[0]));
        }
        applyFirmographics(a, firmo);
        a.QubitOn_Out_of_Business__c = str(h.get('companyMarketIndicator')).equalsIgnoreCase('OB') || h.get('outOfBusinessDate') != null;
        a.QubitOn_Year_Started__c = usable ? (String) h.get('yearStarted') : null;
        a.QubitOn_Line_of_Business__c = usable ? (String) h.get('lineOfBusiness') : null;
        a.QubitOn_Location_Type__c = usable ? (String) h.get('locationType') : null;
        // Industry codes, in the classification answer's shape so the primary rule is the same.
        List<Object> codes = new List<Object>();
        if (usable && h.get('entityBusinessClassifications') instanceof List<Object>)
            for (Object o : (List<Object>) h.get('entityBusinessClassifications')) {
                if (!(o instanceof Map<String, Object>)) continue;
                Map<String, Object> c = (Map<String, Object>) o;
                codes.add(new Map<String, Object>{
                    'industryCodeType' => ((String) c.get('businessClassificationSubType'))?.toUpperCase(),
                    'industryCodeValue' => c.get('businessClassificationNumber'),
                    'industryCodeDescription' => c.get('businessClassificationDescription'),
                    'rank' => c.get('rank'), 'role' => c.get('role'), 'confidence' => c.get('confidence') });
            }
        applyIndustryCodes(a, codes);
        if (usable) {
            applyCertifications(a, h.get('entityCertificates') instanceof List<Object> ? (List<Object>) h.get('entityCertificates') : new List<Object>());
            if (a.QubitOn_Certification_Match_Confidence__c == null) a.QubitOn_Certification_Match_Confidence__c = conf;
        } else {
            a.QubitOn_Certification_Types__c = null; a.QubitOn_Certification_Agencies__c = null; a.QubitOn_Certification_Match_Confidence__c = null;
        }
        a.QubitOn_Payment_Methods__c = usable ? activeNames(h.get('entityPaymentMethods'), 'paymentMethod', 'isAccepted') : null;
        a.QubitOn_Risk_Flags__c = usable ? activeNames(h.get('entityRiskFlags'), 'flagType', 'isFlagged') : null;
    }

    /** "CHECK; EFT_ACH": items whose flag is true, status not ended or inactive, and no end date; cut at 255. */
    @TestVisible static String activeNames(Object raw, String nameKey, String flagKey) {
        List<String> out = new List<String>();
        if (raw instanceof List<Object>)
            for (Object o : (List<Object>) raw) {
                if (!(o instanceof Map<String, Object>)) continue;
                Map<String, Object> m = (Map<String, Object>) o;
                String n = (String) m.get(nameKey), st = str(m.get('status')).toUpperCase();
                if (String.isBlank(n) || m.get(flagKey) != true || m.get('endedDate') != null || st == 'ENDED' || st == 'INACTIVE') continue;
                if (!out.contains(n)) out.add(n);
            }
        return joinLimited(out, 255);
    }

    private static String str(Object o) { return o == null ? '' : String.valueOf(o); }

    /** Fields only data lookup fills; cleared when the fallback path runs so an old value does not linger. */
    private static void clearLookupOnlyFields(Account a) {
        a.QubitOn_Matched_On__c = null; a.QubitOn_Address_Not_Matched__c = false;
        a.QubitOn_Payment_Methods__c = null; a.QubitOn_Risk_Flags__c = null;
    }

    /** One certification from /api/certification/lookup. */
    @TestVisible class Certification implements Comparable {
        public String type, agency, confidence; public Decimal score; public Date expires; public Integer seq;
        public Integer compareTo(Object o) {
            Certification b = (Certification) o;
            // Best first: higher match score, then the later expiry (no recorded expiry after dated ones), then API order.
            Decimal sa = score == null ? -1 : score, sb = b.score == null ? -1 : b.score;
            if (sa != sb) return sa > sb ? -1 : 1;
            if (expires != b.expires) {
                if (expires == null) return 1;
                if (b.expires == null) return -1;
                return expires > b.expires ? -1 : 1;
            }
            return seq == b.seq ? 0 : (seq < b.seq ? -1 : 1);
        }
    }

    /** Active certifications, best first: types (with expiry when known) and agencies, each cut on whole items at 255.
     *  A no-match answer is one item with score 0 and no certificationType. Expired certifications are counted, not listed. */
    @TestVisible static void applyCertifications(Account a, List<Object> rs) {
        List<Certification> active = new List<Certification>();
        Integer expired = 0, seq = 0;
        String fallbackConfidence = null;
        for (Object o : rs) {
            if (!(o instanceof Map<String, Object>)) continue;
            Map<String, Object> m = (Map<String, Object>) o;
            if (fallbackConfidence == null) fallbackConfidence = confidenceWord(m.get('matchConfidence'), false);
            String t = ((String) m.get('certificationType'))?.normalizeSpace();
            if (String.isBlank(t)) continue;
            Certification c = new Certification();
            c.type = t;
            String ag = (String) m.get('certificationAgency');
            c.agency = (String.isBlank(ag) ? (String) m.get('alternateCertificationAgency') : ag)?.normalizeSpace();
            c.confidence = confidenceWord(m.get('matchConfidence'), false);
            c.score = num(m.get('score'));
            c.expires = toDate(m.get('expirationDate'));
            c.seq = seq++;
            if (c.expires != null && c.expires < Date.today()) { expired++; continue; }
            active.add(c);
        }
        active.sort();
        List<String> types = new List<String>(), agencies = new List<String>();
        for (Certification c : active) {
            String item = c.type + (c.expires == null ? '' : ' (exp ' + String.valueOf(c.expires) + ')');
            if (!types.contains(item)) types.add(item);
            if (String.isNotBlank(c.agency) && !agencies.contains(c.agency)) agencies.add(c.agency);
        }
        a.QubitOn_Certification_Types__c = !types.isEmpty() ? joinLimited(types, 255)
            : (expired > 0 ? 'None active (' + expired + ' expired)' : 'None found');
        a.QubitOn_Certification_Agencies__c = joinLimited(agencies, 255);
        a.QubitOn_Certification_Match_Confidence__c = !active.isEmpty() && active[0].confidence != null
            ? active[0].confidence : fallbackConfidence;
    }
    private static Date toDate(Object o) {
        if (o == null) return null;
        try { return Date.valueOf(String.valueOf(o).left(10)); } catch (Exception e) { return null; }
    }

    /** Corporate hierarchy TYPE: DATA_FOUND (with linkages), NO_HIERARCHY (company matched, no relatives), NO_DATA. */
    @TestVisible static String hierarchyStatus(List<Object> rs) {
        if (rs.isEmpty()) return 'No hierarchy data';
        Map<String, Object> g = (Map<String, Object>) ((Map<String, Object>) rs[0]).get('elsGenericMessage');
        Map<String, Object> msg = g == null ? null : (Map<String, Object>) g.get('message');
        String type = msg == null ? null : String.valueOf(msg.get('TYPE'));
        Integer linked = null;
        Object s2 = g == null ? null : g.get('stage2Data');
        if (s2 instanceof Map<String, Object>) {
            Object bd = ((Map<String, Object>) s2).get('businessData');
            Object sum = bd instanceof Map<String, Object> ? ((Map<String, Object>) bd).get('corporateLinkageSummary') : null;
            Object cl = sum instanceof Map<String, Object> ? ((Map<String, Object>) sum).get('corporateLinkage') : null;
            if (cl instanceof List<Object>) linked = ((List<Object>) cl).size();
        }
        if (type == 'NO_DATA') return 'No hierarchy data';
        if (type == 'NO_HIERARCHY' || linked == 0) return 'Matched, no related companies';
        return linked == null ? 'Found' : 'Found: ' + linked + ' related companies';
    }

    private static Decimal num(Object o) {
        if (o == null) return null;
        try { Decimal d = Decimal.valueOf(String.valueOf(o).replace(',', '')); return d > 0 ? d : null; }
        catch (Exception e) { return null; }
    }

    /** True when the org has the standard Tradestyle (DBA) field; it is sent to data lookup as the DBA name. */
    public static final Boolean HAS_TRADESTYLE = Schema.SObjectType.Account.fields.getMap().containsKey('tradestyle');
    /** Set after a 403 from data lookup so the other accounts in the same job skip the call. */
    @TestVisible static Boolean lookupNotEntitled = false;

    /** True when the org has State and Country/Territory Picklists enabled. */
    public static final Boolean HAS_CODES = Schema.SObjectType.Account.fields.getMap().containsKey('billingcountrycode');

    /** ISO code when picklists are on, else the free-text value (the API accepts ISO2, ISO3 or names). */
    /** Blank, "United States" and "USA" become "US"; anything else is passed through. */
    public static String normalizeCountry(String c) {
        if (String.isBlank(c) || c == 'United States' || c == 'USA') return 'US';
        return c;
    }

    public static String pick(SObject r, String codeField, String textField) {
        if (HAS_CODES) { String c = (String) r.get(codeField); if (String.isNotBlank(c)) return c; }
        return (String) r.get(textField);
    }

    private static Boolean anyPass(Object results) {
        if (!(results instanceof List<Object>)) return false;
        for (Object o : (List<Object>) results) if (((Map<String, Object>) o).get('validationPass') == true) return true;
        return false;
    }
    private static String firstDescription(Object results) {
        if (!(results instanceof List<Object>) || ((List<Object>) results).isEmpty()) return null;
        return String.valueOf(((Map<String, Object>) ((List<Object>) results)[0]).get('validationDescription'));
    }

    @TestVisible
    private static void screen(Account a) {
        List<String> errors = new List<String>();
        String country = normalizeCountry(pick(a, 'BillingCountryCode', 'BillingCountry'));
        String state = pick(a, 'BillingStateCode', 'BillingState');
        String zip5 = a.BillingPostalCode == null ? null : a.BillingPostalCode.left(5);

        // 1. Address
        if (String.isNotBlank(a.BillingStreet)) {
            try {
                Map<String, Object> r = QubitOnService.validateAddress(a.BillingStreet, a.BillingCity, state, a.BillingPostalCode, country);
                Boolean valid = anyPass(r.get('validationResults'));
                a.QubitOn_Address_Status__c = valid ? 'Valid' : 'Not verified';
                // Classification needs a state; many non-US records have none, so use the validated one.
                if (valid && String.isBlank(state) && String.isNotBlank((String) r.get('state'))) state = (String) r.get('state');
                a.QubitOn_Standardized_Address__c = String.join(new List<String>{
                    (String) r.get('address1'), (String) r.get('city'), (String) r.get('state'), (String) r.get('postalCode') }, ', ');
            } catch (Exception e) { errors.add('Address: ' + e.getMessage()); }
        }
        // 2. Phone
        if (String.isNotBlank(a.Phone)) {
            try {
                Map<String, Object> r = QubitOnService.validatePhone(a.Phone, country);
                a.QubitOn_Phone_Status__c = anyPass(r.get('validationResults')) ? 'Valid' : 'Not verified';
            } catch (Exception e) { errors.add('Phone: ' + e.getMessage()); }
        }
        // 3. Tax ID
        if (String.isNotBlank(a.QubitOn_Tax_ID__c)) {
            try {
                String type = String.isBlank(a.QubitOn_Tax_ID_Type__c) ? 'EIN' : a.QubitOn_Tax_ID_Type__c;
                Map<String, Object> r = QubitOnService.validateTaxId(a.Name, a.QubitOn_Tax_ID__c.replaceAll('[^A-Za-z0-9]', ''), type, country);
                String d = firstDescription(r.get('validationResults'));
                a.QubitOn_Tax_Status__c = ((anyPass(r.get('validationResults')) ? 'Valid: ' : 'Not verified: ') + (d == null ? '' : d)).left(255);
            } catch (Exception e) { errors.add('Tax: ' + e.getMessage()); }
        }
        // 4. Data lookup (enterprise plans): match confidence, firmographics, industry codes, certifications,
        //    payment methods and risk flags in one call.
        Boolean viaLookup = false;
        if (useDataLookup() && !lookupNotEntitled) {
            try {
                applyDataLookup(a, QubitOnService.dataLookup(a.Name, HAS_TRADESTYLE ? (String) a.get('Tradestyle') : null,
                    a.BillingStreet, a.BillingCity, state, a.BillingPostalCode, country, a.Phone, a.Website));
                viaLookup = true;
            } catch (QubitOnService.QubitOnException e) {
                if (e.statusCode == 403) lookupNotEntitled = true; // not on the plan: fall back silently
                else errors.add('Data lookup (used classification instead): ' + e.getMessage());
            } catch (Exception e) { errors.add('Data lookup (used classification instead): ' + e.getMessage()); }
        }
        if (!viaLookup) {
            if (useDataLookup()) clearLookupOnlyFields(a); // off: exactly the classification path, fields untouched
            // 4a. Business classification (SIC, line of business, year started)
            if (String.isNotBlank(a.BillingCity) && String.isNotBlank(state)) { // API requires city + state
                try {
                    List<Object> rs = QubitOnService.businessClassification(a.Name, a.BillingStreet, a.BillingCity, state, a.BillingPostalCode, country);
                    if (!rs.isEmpty()) {
                        Map<String, Object> r = (Map<String, Object>) rs[0];
                        applyIndustryCodes(a, r.get('industryCode'));
                        applyFirmographics(a, r);
                        a.QubitOn_Line_of_Business__c = ((String) r.get('lineOfBusiness'));
                        a.QubitOn_Year_Started__c = (String) r.get('yearStarted');
                        a.QubitOn_Location_Type__c = (String) r.get('locationType');
                        Object conf = r.get('confidenceCode');
                        a.QubitOn_Confidence_Code__c = conf == null ? null : Decimal.valueOf(String.valueOf(conf));
                        a.QubitOn_Match_Confidence__c = confidenceWord(r.get('matchConfidence'), false);
                    }
                } catch (Exception e) { errors.add('Classification: ' + e.getMessage()); }
            }
            // 4b. Certifications (diversity / small business)
            try {
                applyCertifications(a, QubitOnService.certificationLookup(a.Name, a.BillingStreet, a.BillingCity, state, country == 'US' ? zip5 : a.BillingPostalCode, country));
            } catch (Exception e) { errors.add('Certifications: ' + e.getMessage()); }
        }
        // 5. Corporate hierarchy (US)
        if (country == 'US' && String.isNotBlank(a.BillingStreet) && String.isNotBlank(zip5)) {
            try {
                a.QubitOn_Hierarchy_Status__c = hierarchyStatus(
                    QubitOnService.corporateHierarchy(a.Name, a.BillingStreet, a.BillingCity, state, zip5));
            } catch (Exception e) { errors.add('Hierarchy: ' + e.getMessage()); }
        }
        // 6. Sanctions / denied party
        try {
            Boolean hit = false; List<String> detail = new List<String>();
            for (Object o : QubitOnService.checkSanctions(a.Name, country, a.BillingCity, state, a.BillingPostalCode)) {
                Map<String, Object> m = (Map<String, Object>) o;
                if (m.get('isMatch') == true) { hit = true; detail.add(String.valueOf(m.get('description'))); }
            }
            a.QubitOn_Sanctions_Status__c = hit ? 'Potential match' : 'Clear';
            a.QubitOn_Sanctions_Detail__c = hit ? String.join(detail, '\n').left(32000) : null;
        } catch (Exception e) { errors.add('Sanctions: ' + e.getMessage()); }
        // 7. Adverse media / fraud
        try {
            Map<String, Object> r = QubitOnService.entityRisk(a.Name);
            Object s = r.get('riskScore');
            a.QubitOn_Adverse_Media_Score__c = s == null ? null : Decimal.valueOf(String.valueOf(s));
            a.QubitOn_High_Risk__c = r.get('isHighRisk') == true;
        } catch (Exception e) { errors.add('Adverse media: ' + e.getMessage()); }
        // 8-10. Financial risk. matchConfidence (High/Medium/Low/None) says how sure the company match behind each answer is.
        List<String> riskConf = new List<String>();
        try {
            Map<String, Object> r = QubitOnService.riskControl(a.Name, 'Credit Score', country);
            Object v = r.get('categoryValue');
            a.QubitOn_Credit_Score__c = (v == null || String.valueOf(v) == '') ? 'No data' : String.valueOf(v);
            addConfidence(riskConf, 'Credit score', r);
        } catch (Exception e) { errors.add('Credit: ' + e.getMessage()); }
        try {
            Map<String, Object> r = QubitOnService.riskControl(a.Name, 'Fail Rate', country);
            Object v = r.get('categoryValue');
            a.QubitOn_Fail_Rate__c = (v == null || String.valueOf(v) == '') ? 'No data' : String.valueOf(v);
            addConfidence(riskConf, 'Fail rate', r);
        } catch (Exception e) { errors.add('Fail rate: ' + e.getMessage()); }
        try {
            Map<String, Object> r = QubitOnService.riskControl(a.Name, 'Bankruptcy', country);
            List<Object> cases = r.get('cases') instanceof List<Object> ? (List<Object>) r.get('cases') : new List<Object>();
            a.QubitOn_Bankruptcy__c = cases.isEmpty() ? 'No filings found' : (cases.size() + ' filing(s) found');
            addConfidence(riskConf, 'Bankruptcy', r);
        } catch (Exception e) { errors.add('Bankruptcy: ' + e.getMessage()); }
        a.QubitOn_Risk_Match_Confidence__c = riskConf.isEmpty() ? null : String.join(riskConf, '; ');

        // 11. Beneficial ownership (registry-backed, ISO2 country required)
        if (country != null && country.length() == 2) {
            try { if (applyOwnership(a, QubitOnService.beneficialOwnership(a.Name, country))) pendingOwnership.add(a.Id); }
            catch (Exception e) { errors.add('Ownership: ' + e.getMessage()); }
        }

        a.QubitOn_Error__c = errors.isEmpty() ? null : String.join(errors, '\n').left(255);
        a.QubitOn_Last_Checked__c = System.now();
    }

    public static final String UBO_PENDING = 'In progress';

    /** " (EPLS, OIG)" from a prohibited-list response: which watch lists matched (sanctions, exclusion, ...). */
    @TestVisible static String listCodes(Map<String, Object> pl) {
        Object info = pl.get('additionalInfo');
        Object lists = info instanceof Map<String, Object> ? ((Map<String, Object>) info).get('lists') : null;
        if (!(lists instanceof List<Object>)) return '';
        List<String> codes = new List<String>();
        for (Object o : (List<Object>) lists) {
            Object c = o instanceof Map<String, Object> ? ((Map<String, Object>) o).get('code') : null;
            if (c != null && !codes.contains(String.valueOf(c))) codes.add(String.valueOf(c));
        }
        return codes.isEmpty() ? '' : ' (' + String.join(codes, ', ') + ')';
    }
    @TestVisible private static Set<Id> pendingOwnership = new Set<Id>();
    public static Boolean applyOwnershipPublic(Account a, List<Object> results) { return applyOwnership(a, results); }

    /** Maps the ownership tree onto the Account. Returns true when the registry lookup is still running. */
    @TestVisible
    private static Boolean applyOwnership(Account a, List<Object> results) {
        a.QubitOn_UBO_Sanctions_Hit__c = false;
        if (results.isEmpty()) { a.QubitOn_UBO_Status__c = 'No data'; a.QubitOn_UBO_Detail__c = null; return false; }
        Map<String, Object> r = (Map<String, Object>) results[0];
        Map<String, Object> tree = (Map<String, Object>) r.get('ownershipTreeField');
        if (tree == null) {
            Map<String, Object> err = (Map<String, Object>) r.get('ErrorResponse');
            a.QubitOn_UBO_Status__c = ('Not available' + (err == null ? '' : ': ' + err.get('message'))).left(60);
            a.QubitOn_UBO_Detail__c = null;
            return false;
        }
        String status = String.valueOf(tree.get('statusField'));
        if (status == 'IN_PROGRESS') { a.QubitOn_UBO_Status__c = UBO_PENDING; return true; }
        List<Object> nodes = tree.get('nodesField') instanceof List<Object> ? (List<Object>) tree.get('nodesField') : new List<Object>();
        // Edges describe each related party: SHAREHOLDER (with %) or REPRESENTATIVE (with a role, e.g. Director)
        Map<String, Map<String, Object>> edgeByNode = new Map<String, Map<String, Object>>();
        for (Object o : nodes) {
            Map<String, Object> n = (Map<String, Object>) o;
            if (n.get('edgesField') instanceof List<Object>)
                for (Object e : (List<Object>) n.get('edgesField')) {
                    Map<String, Object> edge = (Map<String, Object>) e;
                    edgeByNode.put(String.valueOf(edge.get('nodeIdField')), edge);
                }
        }
        List<String> owners = new List<String>(), officers = new List<String>();
        for (Object o : nodes) {
            Map<String, Object> n = (Map<String, Object>) o;
            Map<String, Object> ent = (Map<String, Object>) n.get('entityField');
            if (ent == null || n.get('levelField') == 1) continue;
            Map<String, Object> pl = (Map<String, Object>) ent.get('prohibitedListResponse');
            Boolean hit = pl != null && pl.get('isMatch') == true;
            if (hit) a.QubitOn_UBO_Sanctions_Hit__c = true;
            Map<String, Object> edge = edgeByNode.get(String.valueOf(ent.get('idField')));
            String who = ent.get('nameField') + ' (' + ent.get('typeField')
                + (ent.get('countryISOField') == null ? '' : ', ' + ent.get('countryISOField')) + ')';
            String flag = hit ? ' LIST MATCH' + listCodes(pl) : '';
            if (edge != null && edge.get('typeField') == 'REPRESENTATIVE') {
                officers.add(who + (edge.get('roleField') == null ? '' : ' ' + edge.get('roleField')) + flag);
            } else {
                Object p = edge == null ? null : edge.get('percentageField');
                Decimal pct = p == null ? null : Decimal.valueOf(String.valueOf(p));
                // 0 means the registry reported no percentage, not a 0% holding.
                owners.add('L' + n.get('levelField') + ' ' + who + (pct == null || pct == 0 ? '' : ' ' + pct.setScale(2) + '%') + flag);
            }
        }
        List<String> lines = new List<String>();
        if (!owners.isEmpty()) { lines.add('Shareholders:'); lines.addAll(owners); }
        if (!officers.isEmpty()) { lines.add('Officers:'); lines.addAll(officers); }
        a.QubitOn_UBO_Status__c = (owners.isEmpty() && officers.isEmpty()) ? 'No owners found'
            : (owners.size() + ' shareholder(s), ' + officers.size() + ' officer(s)');
        a.QubitOn_UBO_Detail__c = String.join(lines, '\n').left(32000);
        return false;
    }
}
