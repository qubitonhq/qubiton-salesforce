@IsTest
private class QubitOnTests {
    /** Routes each QubitOn endpoint to a canned response shaped like the live API. */
    private class Mock implements HttpCalloutMock {
        Boolean hit; Integer failCode; Integer calls = 0; String uboMode = 'SUCCESS'; String classState; Boolean oldContract = false;
        String dlMode = '403'; Map<String, Object> dlBody; Map<String, Integer> hits = new Map<String, Integer>();
        Mock(Boolean hit, Integer failCode) { this.hit = hit; this.failCode = failCode; }
        public HttpResponse respond(HttpRequest req) {
            calls++;
            HttpResponse r = new HttpResponse();
            r.setHeader('Content-Type', 'application/json');
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
            System.assertEquals('Salesforce Connector', body.get('RequestedByClient'));
            System.assert(req.getEndpoint().startsWith('callout:QubitOn/'), req.getEndpoint());
            if (failCode != null) { r.setStatusCode(failCode); r.setBody('{"error":"x"}'); return r; }
            r.setStatusCode(200);
            String ep = req.getEndpoint().substringAfter('callout:QubitOn');
            hits.put(ep, (hits.containsKey(ep) ? hits.get(ep) : 0) + 1);
            if (ep == '/api/qubitondatalookup/lookup') {
                dlBody = body;
                if (dlMode == '403') { r.setStatusCode(403); r.setBody('{"error":"Not enabled for this plan"}'); return r; }
                if (dlMode == '500') { r.setStatusCode(500); r.setBody('{"error":"x"}'); return r; }
                r.setStatusCode(200);
                r.setBody(dlAnswer(dlMode));
                return r;
            }
            String pass = '"validationResults":[{"validationPass":true,"validationDescription":"TIN and Name combination matches IRS EIN records"}]';
            if (ep == '/api/address/validate') r.setBody('{"address1":"1 Main St","city":"Austin","state":"TX","postalCode":"78701-0001",' + pass + '}');
            else if (ep == '/api/phone/validate') r.setBody('{"fullPhoneNumber":"+15125550100",' + pass + '}');
            else if (ep == '/api/email/validate') r.setBody('{"emailAddress":"a@b.com",' + pass + '}');
            else if (ep == '/api/tax/validate') {
                System.assertEquals('911144442', body.get('IdentityNumber'));
                r.setBody('{"identityNumberType":"EIN",' + pass + '}');
            }
            else if (ep == '/api/businessclassification/lookup' && (classState = (String) body.get('state')) != null) r.setBody(oldContract
                // Contract before data/api #8612 and #8764: no rank, role, confidence or matchConfidence.
                ? '[{"lineOfBusiness":"Prepackaged software","confidenceCode":8,"industryCode":[{"industryCodeType":"SIC","industryCodeValue":"7372","industryCodeDescription":"Prepackaged Software"},{"industryCodeType":"NAICS","industryCodeValue":"513210","industryCodeDescription":"Software Publishers"}]}]'
                // Current contract: ranked per type, not globally ordered (as live on build 36257), one primary NAICS.
                : '[{"lineOfBusiness":"Prepackaged software","yearStarted":"1975","locationType":"Headquarters","confidenceCode":10,"matchConfidence":"Medium","industryCode":['
                + '{"industryCodeType":"SIC","industryCodeValue":"7372","industryCodeDescription":"Prepackaged Software","rank":1,"role":"secondary","confidence":"Low"},'
                + '{"industryCodeType":"SIC","industryCodeValue":"73729905","industryCodeDescription":"x","rank":2,"role":"secondary","confidence":"Low"},'
                + '{"industryCodeType":"NAICS","industryCodeValue":"541511","industryCodeDescription":"Custom Computer Programming Services","rank":2,"role":"secondary","confidence":"Low"},'
                + '{"industryCodeType":"NAICS","industryCodeValue":"513210","industryCodeDescription":"Software Publishers","rank":1,"role":"primary","confidence":"High"}],'
                + '"employeesTotal":83334,"salesVolume":34857000000,"website":"salesforce.com","stockExchange":"NYSE","tickerSymbol":"CRM","isPublic":true,"isWomenOwned":true,"isSmallBusiness":false,"isOutOfBusiness":false,"dataSource":"Equifax","matchedRecordId":"12345678"}]');
            else if (ep == '/api/certification/lookup') r.setBody(oldContract
                // Prod build 36257 shape: type and group only, no agency, dates or matchConfidence.
                ? '[{"certificationType":"WBE","certificationGroup":"WBE","certificationSource":"QubitOn","score":80}]'
                : '[{"certificationType":"SBE","certificationAgency":"SBA","score":80,"expirationDate":"2099-12-31T00:00:00","matchConfidence":"High"},'
                + '{"certificationType":"WBE","alternateCertificationAgency":"WBENC","score":100,"matchConfidence":"High"},'
                + '{"certificationType":"MBE","certificationAgency":"NMSDC","score":100,"expirationDate":"2020-01-31T00:00:00","matchConfidence":"High"}]');
            else if (ep == '/api/corporatehierarchy/lookup') r.setBody(hit
                ? '[{"elsGenericMessage":{"stage2Data":{"businessData":{"corporateLinkageSummary":{"corporateLinkage":[{"linkageCompanyName":"A"},{"linkageCompanyName":"B"}]}}},"message":{"TYPE":"DATA_FOUND"}}}]'
                : '[{"elsGenericMessage":{"message":{"TYPE":"NO_DATA"}}}]');
            else if (ep == '/api/prohibited/lookup') r.setBody('[{"isMatch":' + hit + ',"description":"List: BIS Score:100"},{"isMatch":false,"description":"Success"}]');
            else if (ep == '/api/pep/lookup') r.setBody(hit ? '[{"persons":[{"name":"Jane PEP"},{"name":"Jane PEP"}]}]' : '[{"persons":[]}]');
            else if (ep == '/api/entity/fraud/lookup') r.setBody('{"riskScore":' + (hit ? 80 : 0) + ',"isHighRisk":' + hit + '}');
            else if (ep == '/api/risk/riskcontrol') {
                String cat = (String) body.get('Category');
                // matchConfidence arrives with data/api #8764; Fail Rate omits it, as an older build would.
                String mc = oldContract ? '' : (cat == 'Credit Score' ? ',"matchConfidence":"Medium"' : ',"matchConfidence":"None"');
                if (cat == 'Credit Score') r.setBody('{"categoryValue":"383"' + mc + '}');
                else if (cat == 'Fail Rate') r.setBody('{"categoryValue":"1.00"}');
                else r.setBody('{"categoryValue":"","cases":' + (hit ? '[{"id":1}]' : '[]') + mc + '}');
            }
            else if (ep == '/api/beneficialownership/lookup') {
                if (uboMode == 'IN_PROGRESS') r.setBody('[{"ownershipTreeField":{"statusField":"IN_PROGRESS","nodesField":[]}}]');
                else if (uboMode == 'ERROR') r.setBody('[{"responseCodeField":"107","ErrorResponse":{"statusCode":500,"message":"INVALID_REGAUTH"}}]');
                else r.setBody('[{"ownershipTreeField":{"statusField":"SUCCESS","nodesField":['
                    + '{"levelField":1,"entityField":{"idField":"root","typeField":"COMPANY","nameField":"ACME LTD"},"edgesField":[{"nodeIdField":"p1","typeField":"SHAREHOLDER","percentageField":75},{"nodeIdField":"p2","typeField":"SHAREHOLDER","percentageField":25},{"nodeIdField":"d1","typeField":"REPRESENTATIVE","percentageField":0,"roleField":"Director"}]},'
                    + '{"levelField":2,"entityField":{"idField":"p1","typeField":"PERSON","nameField":"Jane Owner","countryISOField":"GB","prohibitedListResponse":{"isMatch":' + hit + ',"additionalInfo":{"lists":[{"code":"EPLS"},{"code":"EPLS"}]}}}},'
                    + '{"levelField":2,"entityField":{"idField":"p2","typeField":"COMPANY","nameField":"Holdco Ltd","countryISOField":"GB"}},'
                    + '{"levelField":2,"entityField":{"idField":"d1","typeField":"PERSON","nameField":"Dan Director"}}]}}]');
            }
            else System.assert(false, 'Unexpected endpoint ' + ep);
            return r;
        }
    }

    /** Data lookup answers shaped like prod build 36257 (MEDIUM, LOW), plus no match, an older build and an error body. */
    private static String dlAnswer(String mode) {
        if (mode == 'NOMATCH') return '[{"requestedByClient":"Salesforce Connector","headerResponse":{"companyName":"X","salesVolume":0}}]';
        if (mode == 'ERRBODY') return '[{"headerResponse":null,"lookupErrorResponse":{"message":"lookup failed"}}]';
        String conf = mode == 'MEDIUM' ? '"matchConfidence":"Medium","matchedOn":["Address","CompanyName","Phone"],'
            : mode == 'LOW' ? '"matchConfidence":"Low","matchedOn":["CompanyName","AddressNotMatched"],' : '';
        String roles = mode == 'OLD' ? '' : ',"role":"primary","confidence":"High"';
        return '[{"requestedByClient":"Salesforce Connector","headerResponse":{"companyName":"Acme","qubitOnEntityId":"' + (mode == 'LOW' ? '7' : '42') + '",' + conf
            + '"employeesTotal":120,"salesVolume":5000000,"url":["acme.example"],"yearStarted":"1999","lineOfBusiness":"Widgets",'
            + '"locationType":"Headquarters","companyMarketIndicator":"' + (mode == 'LOW' ? 'OB' : 'A') + '",'
            + '"entityBusinessClassifications":['
            + '{"businessClassificationSubType":"SIC","businessClassificationNumber":"3599","businessClassificationDescription":"Industrial Machinery","rank":1' + roles + '},'
            + '{"businessClassificationSubType":"SIC","businessClassificationNumber":"3599","businessClassificationDescription":"INDUSTRIAL MACHINERY","rank":2},'
            + '{"businessClassificationSubType":"naics","businessClassificationNumber":"332710","businessClassificationDescription":"Machine Shops","rank":1},"junk"],'
            + '"entityCertificates":[{"certificationType":"WOSB","certificationAgency":"SBA","expirationDate":"2099-12-31T00:00:00Z","score":80}],'
            + '"entityPaymentMethods":[{"paymentMethod":"CHECK","isAccepted":true,"status":"ACTIVE"},{"paymentMethod":"WIRE","isAccepted":true,"status":"ACTIVE","endedDate":"2025-01-01T00:00:00Z"},'
            + '{"paymentMethod":"CARD","isAccepted":false,"status":"ACTIVE"},{"paymentMethod":"EFT_ACH","isAccepted":true,"status":"Ended"},{"paymentMethod":"CHECK","isAccepted":true}],'
            + '"entityRiskFlags":[{"flagType":"SHELL_COMPANY","isFlagged":true,"status":"ACTIVE"},{"flagType":"OLD_FLAG","isFlagged":false}]}}]';
    }

    private static void enableDataLookup() {
        insert new QubitOn_Settings__c(SetupOwnerId = UserInfo.getOrganizationId(), Use_Data_Lookup__c = true);
    }

    private static Account acct(String name) {
        return new Account(Name = name, Phone = '512-555-0100', BillingStreet = '1 Main St', BillingCity = 'Austin',
            BillingState = 'Texas', BillingPostalCode = '78701', BillingCountry = 'United States', QubitOn_Tax_ID__c = '91-1144442');
    }
    private static Account load() {
        return [SELECT QubitOn_Address_Status__c, QubitOn_Standardized_Address__c, QubitOn_Phone_Status__c, QubitOn_Tax_Status__c,
                QubitOn_SIC_Codes__c, QubitOn_Line_of_Business__c, QubitOn_Year_Started__c, QubitOn_Location_Type__c,
                QubitOn_Match_Confidence__c, QubitOn_Hierarchy_Status__c, QubitOn_Sanctions_Status__c, QubitOn_Sanctions_Detail__c,
                QubitOn_Adverse_Media_Score__c, QubitOn_High_Risk__c, QubitOn_Credit_Score__c, QubitOn_Fail_Rate__c,
                QubitOn_Bankruptcy__c, QubitOn_Last_Checked__c, QubitOn_Error__c, QubitOn_NAICS_Codes__c, QubitOn_Employees__c,
                QubitOn_Revenue__c, QubitOn_Website__c, QubitOn_Ticker__c, QubitOn_Diversity__c, QubitOn_Out_of_Business__c,
                QubitOn_Data_Source__c, QubitOn_Record_ID__c, QubitOn_Confidence_Code__c, QubitOn_Primary_NAICS__c,
                QubitOn_Primary_SIC__c, QubitOn_Risk_Match_Confidence__c, QubitOn_Certification_Types__c,
                QubitOn_Certification_Agencies__c, QubitOn_Certification_Match_Confidence__c, QubitOn_Matched_On__c,
                QubitOn_Address_Not_Matched__c, QubitOn_Payment_Methods__c, QubitOn_Risk_Flags__c, Website, NumberOfEmployees, AnnualRevenue, TickerSymbol FROM Account LIMIT 1];
    }

    @IsTest static void cleanAccountGetsAllTenChecks() {
        Mock m = new Mock(false, null);
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest(); insert acct('Clean Co'); Test.stopTest();
        Account a = load();
        System.assertEquals(12, m.calls, 'one callout per check; data lookup is off by default');
        System.assertEquals(null, m.hits.get('/api/qubitondatalookup/lookup'));
        System.assertEquals('Valid', a.QubitOn_Address_Status__c);
        System.assert(a.QubitOn_Standardized_Address__c.contains('78701-0001'));
        System.assertEquals('Valid', a.QubitOn_Phone_Status__c);
        System.assert(a.QubitOn_Tax_Status__c.startsWith('Valid: TIN and Name'));
        System.assertEquals('7372 Prepackaged Software (S, Low)', a.QubitOn_SIC_Codes__c, '8-digit SIC codes are dropped');
        System.assertEquals(null, a.QubitOn_Primary_SIC__c, 'no SIC code is primary');
        System.assertEquals('Prepackaged software', a.QubitOn_Line_of_Business__c);
        System.assertEquals('513210 Software Publishers (P, High); 541511 Custom Computer Programming Services (S, Low)',
            a.QubitOn_NAICS_Codes__c, 'rank order, not response order');
        System.assertEquals('513210 Software Publishers', a.QubitOn_Primary_NAICS__c);
        System.assertEquals(83334, a.QubitOn_Employees__c);
        System.assertEquals(34857000000L, a.QubitOn_Revenue__c);
        System.assertEquals('salesforce.com', a.QubitOn_Website__c);
        System.assertEquals('NYSE: CRM', a.QubitOn_Ticker__c);
        System.assertEquals('Women-owned; Public company', a.QubitOn_Diversity__c);
        System.assertEquals(false, a.QubitOn_Out_of_Business__c);
        System.assertEquals('Equifax', a.QubitOn_Data_Source__c);
        System.assertEquals('12345678', a.QubitOn_Record_ID__c);
        System.assertEquals('salesforce.com', a.Website, 'blank standard field is filled');
        System.assertEquals(83334, a.NumberOfEmployees);
        System.assertEquals(34857000000L, a.AnnualRevenue);
        System.assertEquals('CRM', a.TickerSymbol);
        System.assertEquals('1975', a.QubitOn_Year_Started__c);
        System.assertEquals('Headquarters', a.QubitOn_Location_Type__c);
        System.assertEquals(10, a.QubitOn_Confidence_Code__c);
        System.assertEquals('Medium', a.QubitOn_Match_Confidence__c);
        System.assertEquals('Credit score: Medium; Bankruptcy: None', a.QubitOn_Risk_Match_Confidence__c, 'absent on Fail Rate');
        System.assertEquals('WBE; SBE (exp 2099-12-31)', a.QubitOn_Certification_Types__c, 'best score first, expired MBE left out');
        System.assertEquals('WBENC; SBA', a.QubitOn_Certification_Agencies__c, 'alternate agency used when the agency is blank');
        System.assertEquals('High', a.QubitOn_Certification_Match_Confidence__c);
        System.assertEquals('No hierarchy data', a.QubitOn_Hierarchy_Status__c);
        System.assertEquals('Clear', a.QubitOn_Sanctions_Status__c);
        System.assertEquals(null, a.QubitOn_Sanctions_Detail__c);
        System.assertEquals(0, a.QubitOn_Adverse_Media_Score__c);
        System.assertEquals(false, a.QubitOn_High_Risk__c);
        System.assertEquals('383', a.QubitOn_Credit_Score__c);
        System.assertEquals('1.00', a.QubitOn_Fail_Rate__c);
        System.assertEquals('No filings found', a.QubitOn_Bankruptcy__c);
        System.assertNotEquals(null, a.QubitOn_Last_Checked__c);
        System.assertEquals(null, a.QubitOn_Error__c);
        Account u = [SELECT QubitOn_UBO_Status__c, QubitOn_UBO_Detail__c, QubitOn_UBO_Sanctions_Hit__c FROM Account LIMIT 1];
        System.assertEquals('2 shareholder(s), 1 officer(s)', u.QubitOn_UBO_Status__c);
        System.assert(u.QubitOn_UBO_Detail__c.contains('Officers:\nDan Director (PERSON) Director'), u.QubitOn_UBO_Detail__c);
        System.assert(u.QubitOn_UBO_Detail__c.contains('L2 Jane Owner (PERSON, GB) 75.00%'), u.QubitOn_UBO_Detail__c);
        System.assert(u.QubitOn_UBO_Detail__c.contains('Holdco Ltd (COMPANY, GB) 25.00%'));
        System.assertEquals(false, u.QubitOn_UBO_Sanctions_Hit__c);
    }

    @IsTest static void firmographicsNeverOverwriteUserData() {
        Account a = new Account(Name = 'X', Website = 'mine.example', NumberOfEmployees = 5, AnnualRevenue = 10, TickerSymbol = 'MINE');
        QubitOnAccountScreening.applyFirmographics(a, new Map<String, Object>{
            'employeesTotal' => '1,200', 'salesVolume' => 0, 'website' => 'theirs.example', 'tickerSymbol' => 'TH',
            'isOutOfBusiness' => true, 'isMinorityOwned' => true, 'isVeteranOwned' => true, 'isNonProfit' => true, 'isSmallBusiness' => true });
        System.assertEquals('mine.example', a.Website);
        System.assertEquals(5, a.NumberOfEmployees);
        System.assertEquals(10, a.AnnualRevenue);
        System.assertEquals('MINE', a.TickerSymbol);
        System.assertEquals(1200, a.QubitOn_Employees__c, 'comma-formatted numbers parse');
        System.assertEquals(null, a.QubitOn_Revenue__c, 'zero revenue means unknown');
        System.assertEquals('TH', a.QubitOn_Ticker__c);
        System.assertEquals(true, a.QubitOn_Out_of_Business__c);
        System.assertEquals('Minority-owned; Veteran-owned; Small business; Nonprofit', a.QubitOn_Diversity__c);
        Account b = new Account(Name = 'Y');
        QubitOnAccountScreening.applyFirmographics(b, new Map<String, Object>{ 'employeesTotal' => 'n/a' });
        System.assertEquals(null, b.QubitOn_Employees__c);
        System.assertEquals(null, b.QubitOn_Diversity__c);
        System.assertEquals(null, b.Website);
    }

    @IsTest static void ownershipSanctionsHitFlagged() {
        Test.setMock(HttpCalloutMock.class, new Mock(true, null));
        Test.startTest(); insert acct('Owned Co'); Test.stopTest();
        Account u = [SELECT QubitOn_UBO_Sanctions_Hit__c, QubitOn_UBO_Detail__c FROM Account LIMIT 1];
        System.assertEquals(true, u.QubitOn_UBO_Sanctions_Hit__c);
        System.assert(u.QubitOn_UBO_Detail__c.contains('Jane Owner (PERSON, GB) 75.00% LIST MATCH (EPLS)'), u.QubitOn_UBO_Detail__c);
    }

    @IsTest static void ownershipInProgressIsRechecked() {
        Mock m = new Mock(false, null); m.uboMode = 'IN_PROGRESS';
        Test.setMock(HttpCalloutMock.class, m);
        QubitOnTriggerGuard.skip = true;
        Account a = acct('Pending Co'); insert a;
        QubitOnTriggerGuard.skip = false;
        Test.startTest(); System.enqueueJob(new QubitOnOwnershipRecheck(new List<Id>{ a.Id }, 1)); Test.stopTest();
        System.assertEquals('Still building after 1 attempt(s)', [SELECT QubitOn_UBO_Status__c FROM Account WHERE Id = :a.Id].QubitOn_UBO_Status__c);
    }

    @IsTest static void ownershipPendingFromScreeningSchedulesRecheck() {
        Mock m = new Mock(false, null); m.uboMode = 'IN_PROGRESS';
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest(); insert acct('Slow Registry Co'); Test.stopTest();
        System.assertEquals(QubitOnAccountScreening.UBO_PENDING, [SELECT QubitOn_UBO_Status__c FROM Account LIMIT 1].QubitOn_UBO_Status__c);
    }

    @IsTest static void ownershipRegistryErrorRecorded() {
        Mock m = new Mock(false, null); m.uboMode = 'ERROR';
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest(); insert acct('Unregistered Co'); Test.stopTest();
        System.assertEquals('Not available: INVALID_REGAUTH', [SELECT QubitOn_UBO_Status__c FROM Account LIMIT 1].QubitOn_UBO_Status__c);
    }

    @IsTest static void ownershipRecheckApiErrorRecorded() {
        Test.setMock(HttpCalloutMock.class, new Mock(false, 503));
        QubitOnTriggerGuard.skip = true;
        Account a = acct('Flaky Co'); insert a;
        QubitOnTriggerGuard.skip = false;
        Test.startTest(); System.enqueueJob(new QubitOnOwnershipRecheck(new List<Id>{ a.Id }, 1)); Test.stopTest();
        Account r = [SELECT QubitOn_UBO_Status__c, QubitOn_Error__c FROM Account WHERE Id = :a.Id];
        System.assertEquals('Error', r.QubitOn_UBO_Status__c);
        System.assert(r.QubitOn_Error__c.contains('HTTP 503'));
    }

    @IsTest static void countryNormalization() {
        System.assertEquals('US', QubitOnAccountScreening.normalizeCountry(null));
        System.assertEquals('US', QubitOnAccountScreening.normalizeCountry('United States'));
        System.assertEquals('US', QubitOnAccountScreening.normalizeCountry('USA'));
        System.assertEquals('GB', QubitOnAccountScreening.normalizeCountry('GB'));
    }

    @IsTest static void ownershipRecheckSucceeds() {
        Test.setMock(HttpCalloutMock.class, new Mock(false, null));
        QubitOnTriggerGuard.skip = true;
        Account a = new Account(Name = 'Done Co', BillingCountry = 'United States'); insert a;
        QubitOnTriggerGuard.skip = false;
        Test.startTest(); System.enqueueJob(new QubitOnOwnershipRecheck(new List<Id>{ a.Id }, 1)); Test.stopTest();
        System.assertEquals('2 shareholder(s), 1 officer(s)', [SELECT QubitOn_UBO_Status__c FROM Account WHERE Id = :a.Id].QubitOn_UBO_Status__c);
    }

    @IsTest static void riskyAccountIsFlagged() {
        Test.setMock(HttpCalloutMock.class, new Mock(true, null));
        Test.startTest(); insert acct('Bad Co'); Test.stopTest();
        Account a = load();
        System.assertEquals('Potential match', a.QubitOn_Sanctions_Status__c);
        System.assert(a.QubitOn_Sanctions_Detail__c.contains('BIS'));
        System.assertEquals(false, a.QubitOn_Sanctions_Detail__c.contains('Success'), 'non-matching lists excluded');
        System.assertEquals(true, a.QubitOn_High_Risk__c);
        System.assertEquals(80, a.QubitOn_Adverse_Media_Score__c);
        System.assertEquals('1 filing(s) found', a.QubitOn_Bankruptcy__c);
        System.assertEquals('Found: 2 related companies', a.QubitOn_Hierarchy_Status__c);
    }

    @IsTest static void apiErrorsAreRecordedNotThrown() {
        Test.setMock(HttpCalloutMock.class, new Mock(false, 402));
        Test.startTest(); insert acct('Err Co'); Test.stopTest();
        Account a = load();
        System.assert(a.QubitOn_Error__c.contains('HTTP 402'));
        System.assertEquals(null, a.QubitOn_Sanctions_Status__c);
        System.assertNotEquals(null, a.QubitOn_Last_Checked__c, 'record still stamped');
    }

    @IsTest static void sparseAccountSkipsInputlessChecks() {
        Mock m = new Mock(false, null);
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest(); insert new Account(Name = 'Name Only Co', BillingCountry = 'United States'); Test.stopTest();
        System.assertEquals(7, m.calls, 'certifications, sanctions, adverse media, 3 financial checks and ownership need just a name and country');
        Account a = load();
        System.assertEquals(null, a.QubitOn_Address_Status__c);
        System.assertEquals('Clear', a.QubitOn_Sanctions_Status__c);
    }

    @IsTest static void unrelatedUpdateDoesNotRescreen() {
        Test.setMock(HttpCalloutMock.class, new Mock(false, null));
        QubitOnTriggerGuard.skip = true;
        Account a = acct('Quiet Co'); insert a;
        QubitOnTriggerGuard.skip = false;
        Test.startTest(); a.Description = 'note'; update a; Test.stopTest();
        System.assertEquals(null, [SELECT QubitOn_Last_Checked__c FROM Account WHERE Id = :a.Id].QubitOn_Last_Checked__c);
    }

    @IsTest static void relevantUpdateRescreens() {
        Test.setMock(HttpCalloutMock.class, new Mock(false, null));
        QubitOnTriggerGuard.skip = true;
        Account a = acct('Moved Co'); insert a;
        QubitOnTriggerGuard.skip = false;
        Test.startTest(); a.BillingCity = 'Dallas'; update a; Test.stopTest();
        System.assertNotEquals(null, [SELECT QubitOn_Last_Checked__c FROM Account WHERE Id = :a.Id].QubitOn_Last_Checked__c);
    }

    @IsTest static void bulkInsertProcessesFirstBatchOnly() {
        Test.setMock(HttpCalloutMock.class, new Mock(false, null));
        List<Account> accs = new List<Account>();
        for (Integer i = 0; i < 12; i++) accs.add(new Account(Name = 'Bulk ' + i));
        Test.startTest(); insert accs; Test.stopTest();
        System.assertEquals(4, QubitOnAccountScreening.perJob(), 'data lookup off: 4 per job');
        System.assertEquals(QubitOnAccountScreening.PER_JOB,
            [SELECT COUNT() FROM Account WHERE QubitOn_Last_Checked__c != null], 'remaining accounts are chained to the next job');
    }

    @IsTest static void contactEmailAndPep() {
        Test.setMock(HttpCalloutMock.class, new Mock(true, null));
        QubitOnTriggerGuard.skip = true;
        Account a = new Account(Name = 'Parent', BillingCountry = 'United Kingdom'); insert a;
        QubitOnTriggerGuard.skip = false;
        Test.startTest(); insert new Contact(FirstName = 'Jane', LastName = 'PEP', Email = 'jane@x.com', AccountId = a.Id); Test.stopTest();
        Contact c = [SELECT QubitOn_Email_Status__c, QubitOn_PEP_Status__c, QubitOn_PEP_Detail__c, QubitOn_Last_Checked__c FROM Contact LIMIT 1];
        System.assertEquals('Valid', c.QubitOn_Email_Status__c);
        System.assertEquals('Potential PEP', c.QubitOn_PEP_Status__c);
        System.assertEquals('Jane PEP', c.QubitOn_PEP_Detail__c, 'duplicate names collapsed');
    }

    @IsTest static void contactCleanAndErrorPaths() {
        Test.setMock(HttpCalloutMock.class, new Mock(false, 500));
        Test.startTest(); insert new Contact(LastName = 'Nobody', Email = 'n@x.com'); Test.stopTest();
        Contact c = [SELECT QubitOn_Error__c, QubitOn_PEP_Status__c FROM Contact LIMIT 1];
        System.assert(c.QubitOn_Error__c.contains('HTTP 500'));
        System.assertEquals(null, c.QubitOn_PEP_Status__c);
    }

    @IsTest static void contactUpdateRules() {
        Test.setMock(HttpCalloutMock.class, new Mock(false, null));
        QubitOnTriggerGuard.skip = true;
        Contact c = new Contact(LastName = 'Same', Email = 's@x.com'); insert c;
        QubitOnTriggerGuard.skip = false;
        Test.startTest(); c.Title = 'CFO'; update c; c.Email = 'new@x.com'; update c; Test.stopTest();
        System.assertEquals('Clear', [SELECT QubitOn_PEP_Status__c FROM Contact WHERE Id = :c.Id].QubitOn_PEP_Status__c);
    }

    @IsTest static void serviceRequiresCompanyName() {
        try { QubitOnService.checkSanctions(' ', 'US', null, null, null); System.assert(false); }
        catch (QubitOnService.QubitOnException e) { System.assert(e.getMessage().contains('companyName')); }
    }

    // ---- Regressions from the 2026-11-15 live test on API build 34987 ----

    @IsTest static void codeListsAreCutOnItemBoundaries() {
        // Live: Apple's NAICS list ended "...Manufacturing; 9211" because the joined string was cut at 255.
        List<String> items = new List<String>{ 'A'.repeat(120), 'B'.repeat(120), '921130 Public Finance Activities' };
        String s = QubitOnAccountScreening.joinLimited(items, 255);
        System.assertEquals('A'.repeat(120) + '; ' + 'B'.repeat(120), s);
        System.assertEquals(null, QubitOnAccountScreening.joinLimited(new List<String>(), 255));
        System.assertEquals('C'.repeat(255), QubitOnAccountScreening.joinLimited(new List<String>{ 'C'.repeat(300) }, 255));
    }

    @IsTest static void hierarchyMatchedWithoutRelativesIsNotFound() {
        // Live: Salesforce, Inc. returns TYPE NO_HIERARCHY with an empty linkage list; it used to show "Found".
        List<Object> noHierarchy = (List<Object>) JSON.deserializeUntyped('[{"elsGenericMessage":{"stage2Data":{"businessData":'
            + '{"corporateLinkageSummary":{"corporateLinkage":[]}}},"message":{"TYPE":"NO_HIERARCHY"}}}]');
        System.assertEquals('Matched, no related companies', QubitOnAccountScreening.hierarchyStatus(noHierarchy));
        System.assertEquals('No hierarchy data', QubitOnAccountScreening.hierarchyStatus(new List<Object>()));
        List<Object> legacy = (List<Object>) JSON.deserializeUntyped('[{"elsGenericMessage":{"message":{"TYPE":"DATA_FOUND"}}}]');
        System.assertEquals('Found', QubitOnAccountScreening.hierarchyStatus(legacy));
    }

    @IsTest static void implausibleRevenueNotCopiedToStandardField() {
        // Live: Microsoft salesVolume 118200 for 223000 employees (millions, not dollars).
        Account a = new Account(Name = 'M');
        QubitOnAccountScreening.applyFirmographics(a, new Map<String, Object>{ 'employeesTotal' => 223000, 'salesVolume' => 118200 });
        System.assertEquals(118200, a.QubitOn_Revenue__c, 'QubitOn field keeps the value as reported');
        System.assertEquals(null, a.AnnualRevenue, 'standard field is not filled with a value of unknown unit');
        System.assertEquals(223000, a.NumberOfEmployees);
        System.assertEquals(true, QubitOnAccountScreening.plausibleRevenue(973000, 3));
        System.assertEquals(true, QubitOnAccountScreening.plausibleRevenue(5000000, null));
        System.assertEquals(false, QubitOnAccountScreening.plausibleRevenue(118200, null), 'live: data lookup, no employee count');
        Account known = new Account(Name = 'K', NumberOfEmployees = 223000);
        QubitOnAccountScreening.applyFirmographics(known, new Map<String, Object>{ 'salesVolume' => 5000000 });
        System.assertEquals(null, known.AnnualRevenue, 'the Account employee count is used when the API sends none');
        System.assertEquals(false, QubitOnAccountScreening.plausibleRevenue(null, 5));
    }

    @IsTest static void missingStateFallsBackToValidatedAddress() {
        // Live: Siemens AG (DE, no state) skipped classification; the API requires State and address validation returns "BY".
        Mock m = new Mock(false, null);
        Test.setMock(HttpCalloutMock.class, m);
        Account a = new Account(Name = 'Euro Co', BillingStreet = '1 Main St', BillingCity = 'Munich', BillingPostalCode = '80333', BillingCountry = 'DE');
        Test.startTest(); QubitOnAccountScreening.screen(a); Test.stopTest();
        System.assertEquals('TX', m.classState, 'state from the validated address is sent');
        System.assertEquals('7372 Prepackaged Software (S, Low)', a.QubitOn_SIC_Codes__c);
    }

    @IsTest static void ownershipZeroPercentIsOmitted() {
        // Live: every Microsoft and Salesforce "Beneficial Owner" edge has percentageField 0 (not reported).
        Account a = new Account(Name = 'Z');
        List<Object> r = (List<Object>) JSON.deserializeUntyped('[{"ownershipTreeField":{"statusField":"SUCCESS","nodesField":['
            + '{"levelField":1,"entityField":{"idField":"C0","typeField":"COMPANY","nameField":"Z"},"edgesField":[{"nodeIdField":"N0","typeField":"Beneficial Owner","percentageField":0}]},'
            + '{"levelField":2,"entityField":{"idField":"N0","typeField":"Individual","nameField":"Pat Owner","countryISOField":"US"}}]}}]');
        QubitOnAccountScreening.applyOwnershipPublic(a, r);
        System.assert(a.QubitOn_UBO_Detail__c.contains('L2 Pat Owner (Individual, US)\n') || a.QubitOn_UBO_Detail__c.endsWith('L2 Pat Owner (Individual, US)'), a.QubitOn_UBO_Detail__c);
        System.assertEquals(false, a.QubitOn_UBO_Detail__c.contains('%'));
    }

    // ---- Industry code rank, role and confidence (data/api #8612) and match confidence (#8764-8766) ----

    private static List<Object> codes(String body) { return (List<Object>) JSON.deserializeUntyped(body); }

    @IsTest static void allLowCodesHaveNoPrimary() {
        // Live 2026-11-16 (build 36257): every Microsoft code is secondary/Low, SIC ranks 4-5 sent after the NAICS codes.
        Account a = new Account(Name = 'M');
        QubitOnAccountScreening.applyIndustryCodes(a, codes('['
            + '{"industryCodeType":"SIC","industryCodeValue":"5045","industryCodeDescription":"Computers","rank":1,"role":"secondary","confidence":"Low"},'
            + '{"industryCodeType":"SIC","industryCodeValue":"7372","industryCodeDescription":"Prepackaged software","rank":2,"role":"secondary","confidence":"Low"},'
            + '{"industryCodeType":"NAICS","industryCodeValue":"511210","industryCodeDescription":"Software Publishers","rank":1,"role":"secondary","confidence":"Low"},'
            + '{"industryCodeType":"SIC","industryCodeValue":"5734","industryCodeDescription":"Software Stores","rank":4,"role":"secondary","confidence":"Low"},'
            + '{"industryCodeType":"SIC","industryCodeValue":"5731","industryCodeDescription":"Electronics Stores","rank":3,"role":"secondary","confidence":"Low"}]'));
        System.assertEquals(null, a.QubitOn_Primary_SIC__c);
        System.assertEquals(null, a.QubitOn_Primary_NAICS__c);
        System.assertEquals('5045 Computers (S, Low); 7372 Prepackaged software (S, Low); 5731 Electronics Stores (S, Low); 5734 Software Stores (S, Low)',
            a.QubitOn_SIC_Codes__c);
        System.assertEquals('511210 Software Publishers (S, Low)', a.QubitOn_NAICS_Codes__c);
    }

    @IsTest static void oldContractKeepsApiOrderWithoutTags() {
        // Older answers and the non-golden path (Apple: dunsNumber, matchGrade, 8-digit SIC) may lack rank/role/confidence.
        Account a = new Account(Name = 'A');
        QubitOnAccountScreening.applyIndustryCodes(a, codes('['
            + '{"industryCodeType":"SIC","industryCodeValue":"3663","industryCodeDescription":"Radio Equipment"},'
            + '{"industryCodeType":"SIC","industryCodeValue":"36639906","industryCodeDescription":"Mobile communication equipment"},'
            + '{"industryCodeType":"SIC","industryCodeValue":"3571"},'
            + '{"industryCodeType":"NAICS","industryCodeValue":"334220","industryCodeDescription":"Radio\\n  Manufacturing"},'
            + '{"industryCodeType":"NAICS","industryCodeValue":null},"junk",'
            + '{"industryCodeType":"ISIC","industryCodeValue":"2630"}]'));
        System.assertEquals('3663 Radio Equipment; 3571', a.QubitOn_SIC_Codes__c, 'API order, 8-digit SIC dropped, no tags');
        System.assertEquals('334220 Radio Manufacturing', a.QubitOn_NAICS_Codes__c, 'line breaks in descriptions collapse (live: Red Cross 445110)');
        System.assertEquals(null, a.QubitOn_Primary_SIC__c, 'no role, so nothing is called primary');
        System.assertEquals(null, a.QubitOn_Primary_NAICS__c);
        Account b = new Account(Name = 'B');
        QubitOnAccountScreening.applyIndustryCodes(b, null);
        System.assertEquals(null, b.QubitOn_SIC_Codes__c);
        System.assertEquals(null, b.QubitOn_NAICS_Codes__c);
    }

    @IsTest static void primaryNeedsMediumOrHighConfidence() {
        Account a = new Account(Name = 'P');
        QubitOnAccountScreening.applyIndustryCodes(a, codes('['
            + '{"industryCodeType":"SIC","industryCodeValue":"3571","industryCodeDescription":"Electronic Computers","rank":1,"role":"primary","confidence":"Low"},'
            + '{"industryCodeType":"NAICS","industryCodeValue":"334111","industryCodeDescription":"Computer Manufacturing","rank":"1","role":"PRIMARY","confidence":"medium"},'
            + '{"industryCodeType":"NAICS","industryCodeValue":"334220","rank":"x","role":"secondary"},'
            + '{"industryCodeType":"NAICS","industryCodeValue":"511210","confidence":"Low"},'
            + '{"industryCodeType":"NAICS","industryCodeValue":"541511","rank":2,"confidence":"Unknown"}]'));
        System.assertEquals(null, a.QubitOn_Primary_SIC__c, 'a Low code is never the primary');
        System.assertEquals('3571 Electronic Computers (P, Low)', a.QubitOn_SIC_Codes__c);
        System.assertEquals('334111 Computer Manufacturing', a.QubitOn_Primary_NAICS__c, 'case-insensitive role and confidence');
        System.assertEquals('334111 Computer Manufacturing (P, Medium); 541511; 334220 (S); 511210 (Low)', a.QubitOn_NAICS_Codes__c,
            'ranked codes first; unparseable rank sorts with the unranked; partial tags');
    }

    @IsTest static void taggedListIsCutOnItemBoundaries() {
        String d = 'D'.repeat(100);
        Account a = new Account(Name = 'L');
        QubitOnAccountScreening.applyIndustryCodes(a, codes('['
            + '{"industryCodeType":"NAICS","industryCodeValue":"111111","industryCodeDescription":"' + d + '","rank":1,"role":"secondary","confidence":"Low"},'
            + '{"industryCodeType":"NAICS","industryCodeValue":"222222","industryCodeDescription":"' + d + '","rank":2,"role":"secondary","confidence":"Low"},'
            + '{"industryCodeType":"NAICS","industryCodeValue":"333333","industryCodeDescription":"' + d + '","rank":3,"role":"secondary","confidence":"Low"}]'));
        System.assertEquals('111111 ' + d + ' (S, Low); 222222 ' + d + ' (S, Low)', a.QubitOn_NAICS_Codes__c);
        System.assert(a.QubitOn_NAICS_Codes__c.length() <= 255);
    }

    @IsTest static void confidenceWords() {
        System.assertEquals('High', QubitOnAccountScreening.confidenceWord('HIGH', false));
        System.assertEquals('Low', QubitOnAccountScreening.confidenceWord(' low ', false));
        System.assertEquals(null, QubitOnAccountScreening.confidenceWord('None', false), 'the picklist has no None');
        System.assertEquals('None', QubitOnAccountScreening.confidenceWord('none', true));
        System.assertEquals(null, QubitOnAccountScreening.confidenceWord('Exact', true));
        System.assertEquals(null, QubitOnAccountScreening.confidenceWord(null, true));
    }

    @IsTest static void oldContractLeavesConfidenceFieldsBlank() {
        // Before data/api #8764-8766 deploy: no matchConfidence on classification or riskcontrol.
        Mock m = new Mock(false, null); m.oldContract = true;
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest(); insert acct('Old Co'); Test.stopTest();
        Account a = load();
        System.assertEquals(null, a.QubitOn_Match_Confidence__c);
        System.assertEquals(8, a.QubitOn_Confidence_Code__c);
        System.assertEquals(null, a.QubitOn_Risk_Match_Confidence__c);
        System.assertEquals('7372 Prepackaged Software', a.QubitOn_SIC_Codes__c);
        System.assertEquals(null, a.QubitOn_Primary_NAICS__c);
        System.assertEquals('383', a.QubitOn_Credit_Score__c);
        System.assertEquals('WBE', a.QubitOn_Certification_Types__c);
        System.assertEquals(null, a.QubitOn_Certification_Agencies__c);
        System.assertEquals(null, a.QubitOn_Certification_Match_Confidence__c);
        System.assertEquals(null, a.QubitOn_Error__c);
    }

    // ---- Certifications (12th call) ----

    private static Account certs(String body) {
        Account a = new Account(Name = 'C');
        QubitOnAccountScreening.applyCertifications(a, (List<Object>) JSON.deserializeUntyped(body));
        return a;
    }

    @IsTest static void certificationNoMatch() {
        // Live: a company with no certification comes back as one item with score 0 and no type.
        Account a = certs('[{"score":0,"validationDate":"2026-11-16T01:05:48Z"}]');
        System.assertEquals('None found', a.QubitOn_Certification_Types__c);
        System.assertEquals(null, a.QubitOn_Certification_Agencies__c);
        System.assertEquals(null, a.QubitOn_Certification_Match_Confidence__c);
        System.assertEquals(null, certs('[{"score":0,"matchConfidence":"None"}]').QubitOn_Certification_Match_Confidence__c, 'None is blank');
        System.assertEquals('Low', certs('[{"score":0,"matchConfidence":"Low"}]').QubitOn_Certification_Match_Confidence__c);
        System.assertEquals('None found', certs('[]').QubitOn_Certification_Types__c);
    }

    @IsTest static void certificationAllExpired() {
        Account a = certs('[{"certificationType":"MBE","expirationDate":"2020-01-31T00:00:00","matchConfidence":"Medium"},'
            + '{"certificationType":"DBE","expirationDate":"2021-06-30"}]');
        System.assertEquals('None active (2 expired)', a.QubitOn_Certification_Types__c);
        System.assertEquals(null, a.QubitOn_Certification_Agencies__c);
        System.assertEquals('Medium', a.QubitOn_Certification_Match_Confidence__c, 'falls back to the first item');
    }

    @IsTest static void certificationOrderingAndLimits() {
        String longAgency = 'A'.repeat(250);
        Account a = certs('["junk",'
            + '{"certificationType":"SBE","certificationAgency":"' + longAgency + '","score":90,"expirationDate":"2098-01-01"},'
            + '{"certificationType":"WOSB","certificationAgency":"SBA","score":90,"expirationDate":"2099-01-01","matchConfidence":"medium"},'
            + '{"certificationType":"HUBZone","certificationAgency":"SBA","score":90,"expirationDate":"not a date"},'
            + '{"certificationType":"  WOSB ","certificationAgency":"SBA","score":90,"expirationDate":"2099-01-01"},'
            + '{"certificationType":"VOSB","certificationAgency":"VA","score":90},'
            + '{"certificationType":"8A","certificationAgency":"SBA"},'
            + '{"certificationType":"","certificationAgency":"X"}]');
        System.assertEquals('WOSB (exp 2099-01-01); SBE (exp 2098-01-01); HUBZone; VOSB; 8A', a.QubitOn_Certification_Types__c,
            'score, then later expiry, undated after dated, then API order; duplicates collapse');
        System.assertEquals('SBA; ' + longAgency, a.QubitOn_Certification_Agencies__c, 'cut on whole agencies at 255');
        System.assertEquals('Medium', a.QubitOn_Certification_Match_Confidence__c, 'from the best certification');
    }

    // ---- Data lookup first, classification and certification as the fallback ----

    @IsTest static void dataLookupReplacesClassificationAndCertification() {
        enableDataLookup();
        Mock m = new Mock(false, null); m.dlMode = 'MEDIUM';
        Test.setMock(HttpCalloutMock.class, m);
        Account in1 = acct('Acme');
        in1.Website = 'acme.example';
        if (QubitOnAccountScreening.HAS_TRADESTYLE) in1.put('Tradestyle', 'Acme Machining');
        Test.startTest(); insert in1; Test.stopTest();
        Account a = load();
        System.assertEquals(11, m.calls, 'data lookup replaces two calls');
        System.assertEquals(null, m.hits.get('/api/businessclassification/lookup'));
        System.assertEquals(null, m.hits.get('/api/certification/lookup'));
        Map<String, Object> h = (Map<String, Object>) m.dlBody.get('headerRequest');
        Map<String, Object> addr = (Map<String, Object>) ((List<Object>) h.get('entityAddresses'))[0];
        System.assertEquals('Physical', addr.get('addressType'), 'without it the API answers 422');
        System.assertEquals('US', addr.get('country'));
        System.assertEquals('512-555-0100', ((Map<String, Object>) ((List<Object>) h.get('entityPhones'))[0]).get('phoneNumber'));
        System.assertEquals('acme.example', ((List<Object>) h.get('URL'))[0]);
        if (QubitOnAccountScreening.HAS_TRADESTYLE) System.assertEquals('Acme Machining', ((List<Object>) h.get('companyNameDBA'))[0]);
        System.assertEquals('Medium', a.QubitOn_Match_Confidence__c);
        System.assertEquals('Address, CompanyName, Phone', a.QubitOn_Matched_On__c);
        System.assertEquals(false, a.QubitOn_Address_Not_Matched__c);
        System.assertEquals('42', a.QubitOn_Record_ID__c);
        System.assertEquals('QubitOn data lookup', a.QubitOn_Data_Source__c);
        System.assertEquals(null, a.QubitOn_Confidence_Code__c);
        System.assertEquals(120, a.QubitOn_Employees__c);
        System.assertEquals(5000000, a.QubitOn_Revenue__c);
        System.assertEquals(5000000, a.AnnualRevenue, '41,667 per employee passes the guard');
        System.assertEquals('1999', a.QubitOn_Year_Started__c);
        System.assertEquals('Widgets', a.QubitOn_Line_of_Business__c);
        System.assertEquals('3599 Industrial Machinery (P, High)', a.QubitOn_SIC_Codes__c, 'duplicate code kept once, best rank');
        System.assertEquals('3599 Industrial Machinery', a.QubitOn_Primary_SIC__c, 'same primary rule as classification');
        System.assertEquals('332710 Machine Shops', a.QubitOn_NAICS_Codes__c);
        System.assertEquals('WOSB (exp 2099-12-31)', a.QubitOn_Certification_Types__c);
        System.assertEquals('SBA', a.QubitOn_Certification_Agencies__c);
        System.assertEquals('Medium', a.QubitOn_Certification_Match_Confidence__c, 'the company match when the item has none');
        System.assertEquals('CHECK', a.QubitOn_Payment_Methods__c, 'ended, not accepted and duplicate methods left out');
        System.assertEquals('SHELL_COMPANY', a.QubitOn_Risk_Flags__c);
        System.assertEquals(false, a.QubitOn_Out_of_Business__c);
        System.assertEquals('Clear', a.QubitOn_Sanctions_Status__c, 'other checks unchanged');
        System.assertEquals(null, a.QubitOn_Error__c);
    }

    @IsTest static void lowMatchLeavesCompanyDataBlank() {
        enableDataLookup();
        Mock m = new Mock(false, null); m.dlMode = 'LOW';
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest(); insert acct('Closest Co'); Test.stopTest();
        Account a = load();
        System.assertEquals(null, m.hits.get('/api/businessclassification/lookup'), 'never filled from a fallback call');
        System.assertEquals('Low', a.QubitOn_Match_Confidence__c);
        System.assertEquals(true, a.QubitOn_Address_Not_Matched__c);
        System.assertEquals('7', a.QubitOn_Record_ID__c);
        System.assertEquals(true, a.QubitOn_Out_of_Business__c, 'out-of-business status always shows');
        System.assertEquals(null, a.QubitOn_Employees__c);
        System.assertEquals(null, a.QubitOn_Revenue__c);
        System.assertEquals(null, a.QubitOn_Website__c);
        System.assertEquals(null, a.QubitOn_Year_Started__c);
        System.assertEquals(null, a.QubitOn_SIC_Codes__c);
        System.assertEquals(null, a.QubitOn_Primary_SIC__c);
        System.assertEquals(null, a.QubitOn_Certification_Types__c);
        System.assertEquals(null, a.QubitOn_Payment_Methods__c);
        System.assertEquals(null, a.QubitOn_Risk_Flags__c);
        System.assertEquals(null, a.NumberOfEmployees, 'standard fields untouched');
        System.assertEquals(null, a.AnnualRevenue);
        System.assertEquals(null, a.Website);
    }

    @IsTest static void dataLookupWithoutConfidenceAndNoMatch() {
        // Older build: no matchConfidence, matchedOn, role or confidence.
        Account a = new Account(Name = 'Old');
        QubitOnAccountScreening.applyDataLookup(a, (Map<String, Object>) ((Map<String, Object>) ((List<Object>) JSON.deserializeUntyped(dlAnswer('OLD')))[0]).get('headerResponse'));
        System.assertEquals(null, a.QubitOn_Match_Confidence__c);
        System.assertEquals(120, a.QubitOn_Employees__c, 'a named company without a confidence counts as a match');
        System.assertEquals('3599 Industrial Machinery', a.QubitOn_SIC_Codes__c, 'no tags');
        System.assertEquals(null, a.QubitOn_Primary_SIC__c);
        System.assertEquals(null, a.QubitOn_Certification_Match_Confidence__c);
        System.assertEquals(null, a.QubitOn_Matched_On__c);
        // No match: the API answers 200 with no QubitOn company.
        enableDataLookup();
        Mock m = new Mock(false, null); m.dlMode = 'NOMATCH';
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest(); insert acct('Nobody Co'); Test.stopTest();
        Account b = load();
        System.assertEquals(null, m.hits.get('/api/certification/lookup'));
        System.assertEquals(null, b.QubitOn_Match_Confidence__c);
        System.assertEquals(null, b.QubitOn_Record_ID__c);
        System.assertEquals(null, b.QubitOn_Data_Source__c);
        System.assertEquals(null, b.QubitOn_Certification_Types__c);
        System.assertEquals(null, b.QubitOn_Error__c);
    }

    @IsTest static void notEntitledFallsBackOncePerJob() {
        enableDataLookup();
        Mock m = new Mock(false, null); // dlMode 403, as on plans without data lookup
        Test.setMock(HttpCalloutMock.class, m);
        Test.startTest(); insert new List<Account>{ acct('One Co'), acct('Two Co') }; Test.stopTest();
        System.assertEquals(1, m.hits.get('/api/qubitondatalookup/lookup'), 'the second account skips the call after a 403');
        System.assertEquals(2, m.hits.get('/api/businessclassification/lookup'));
        System.assertEquals(2, m.hits.get('/api/certification/lookup'));
        for (Account a : [SELECT QubitOn_Error__c, QubitOn_SIC_Codes__c, QubitOn_Matched_On__c FROM Account]) {
            System.assertEquals(null, a.QubitOn_Error__c, 'a 403 is expected, not an error');
            System.assertEquals('7372 Prepackaged Software (S, Low)', a.QubitOn_SIC_Codes__c);
            System.assertEquals(null, a.QubitOn_Matched_On__c);
        }
    }

    @IsTest static void unavailableDataLookupFallsBackAndSaysSo() {
        enableDataLookup();
        Mock m = new Mock(false, null); m.dlMode = '500';
        Test.setMock(HttpCalloutMock.class, m);
        Account a = acct('Down Co');
        Test.startTest(); QubitOnAccountScreening.screen(a); m.dlMode = 'ERRBODY'; Account b = acct('Bad Body Co'); QubitOnAccountScreening.screen(b); Test.stopTest();
        System.assert(a.QubitOn_Error__c.startsWith('Data lookup (used classification instead): HTTP 500'), a.QubitOn_Error__c);
        System.assertEquals('7372 Prepackaged Software (S, Low)', a.QubitOn_SIC_Codes__c);
        System.assertEquals('WBE; SBE (exp 2099-12-31)', a.QubitOn_Certification_Types__c);
        System.assert(b.QubitOn_Error__c.contains('lookup failed'), b.QubitOn_Error__c);
        System.assertEquals(2, m.hits.get('/api/qubitondatalookup/lookup'), 'a 500 is not a 403: the next account still tries');
    }

    @IsTest static void activeNamesEdges() {
        System.assertEquals(null, QubitOnAccountScreening.activeNames(null, 'flagType', 'isFlagged'));
        System.assertEquals(null, QubitOnAccountScreening.activeNames(new List<Object>{ 'x', new Map<String, Object>{ 'isFlagged' => true } }, 'flagType', 'isFlagged'));
        System.assertEquals('A', QubitOnAccountScreening.activeNames(new List<Object>{
            new Map<String, Object>{ 'flagType' => 'A', 'isFlagged' => true, 'status' => 'Active' },
            new Map<String, Object>{ 'flagType' => 'B', 'isFlagged' => true, 'status' => 'inactive' } }, 'flagType', 'isFlagged'));
    }

    @IsTest static void dataLookupSettingOffNeverCallsIt() {
        Mock m = new Mock(false, null); m.dlMode = 'MEDIUM';
        Test.setMock(HttpCalloutMock.class, m);
        System.assertEquals(false, QubitOnAccountScreening.useDataLookup(), 'off without a settings record');
        insert new QubitOn_Settings__c(SetupOwnerId = UserInfo.getOrganizationId(), Use_Data_Lookup__c = false);
        Test.startTest(); insert acct('Classic Co'); Test.stopTest();
        Account a = load();
        System.assertEquals(null, m.hits.get('/api/qubitondatalookup/lookup'));
        System.assertEquals(1, m.hits.get('/api/businessclassification/lookup'));
        System.assertEquals(1, m.hits.get('/api/certification/lookup'));
        System.assertEquals('Equifax', a.QubitOn_Data_Source__c);
        System.assertEquals(null, a.QubitOn_Matched_On__c);
        System.assertEquals(4, QubitOnAccountScreening.perJob());
    }

    @IsTest static void dataLookupSettingOnUsesThreePerJob() {
        enableDataLookup();
        System.assertEquals(true, QubitOnAccountScreening.useDataLookup());
        System.assertEquals(3, QubitOnAccountScreening.perJob());
        Mock m = new Mock(false, null); m.dlMode = 'MEDIUM';
        Test.setMock(HttpCalloutMock.class, m);
        List<Account> accs = new List<Account>();
        for (Integer i = 0; i < 5; i++) accs.add(new Account(Name = 'DL ' + i, BillingCountry = 'United States'));
        Test.startTest(); insert accs; Test.stopTest();
        System.assertEquals(3, [SELECT COUNT() FROM Account WHERE QubitOn_Last_Checked__c != null]);
        System.assertEquals(3, m.hits.get('/api/qubitondatalookup/lookup'));
    }
}
