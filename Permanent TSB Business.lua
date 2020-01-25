local BANK_CODE = "Permanent TSB Business"

WebBanking{version     = 1.01,
           url         = "https://www.business24.ie/online/",
           services    = {BANK_CODE},
           description = string.format(MM.localizeText("Get balance and transactions for %s"), BANK_CODE)}

function SupportsBank (protocol, bankCode)
    return protocol == ProtocolWebBanking and bankCode == BANK_CODE
end

local connection = nil
local logoutUrl = nil
local startPage = nil

function InitializeSession (protocol, bankCode, username, username2, password, username3)
    -- Split password and PAN
    local index, _, pass, pan = string.find(password, "^(.+)%-([%d]+)$")
    if index ~= 1 then
        return "Please enter your password followed by a minus sign and your six-digit PAN. (example: password-123456)"
    end
    
    connection = Connection()
    
    -- step 1 (username/password)
    local step1Page = HTML(connection:get(url))
    step1Page:xpath("//input[@id='login-number']"):attr("value", username)
    step1Page:xpath("//input[@id='login-password']"):attr("value", pass)

    local step2Page = HTML(connection:request(step1Page:xpath("//button[@id='btnsubmit']"):click()))

    local errorElement = step2Page:xpath("//div[@class='module-logout']/*/p")
    if errorElement:length() > 0 then
        return errorElement:text()
    end
    
    -- step 2 (PAN)
    for i = 1, 3 do
        local challengeStr = step2Page:xpath("//label[@for='login-digit-" .. i .. "']"):text()
        local characterIndex = tonumber(string.match(challengeStr, "^Digit (%d+)"))

        if characterIndex > string.len(pan) then
            return "PAN is incorrect."
        end

        local answer = string.sub(pan, characterIndex, characterIndex)
        step2Page:xpath("//input[@id='login-digit-" .. i .. "']"):attr("value", answer)
    end
    
    startPage = HTML(connection:request(step2Page:xpath("//button[@id='submit']"):click()))

    local errorElement = startPage:xpath("//*[@class='module-error']/*/div[@class='notice']/*/li")
    if errorElement:length() > 0 then
        return errorElement:text()
    end

    -- startpage
    local logoutButton = startPage:xpath("//a[text()='Logout']")
    if logoutButton:length() == 1 then
        logoutUrl = logoutButton:attr("href")
        print(startPage:xpath("//div[contains(@class, 'module-last-logon')]/*/p"):text())
    else
        return LoginFailed
    end

end

function ListAccounts(knownAccounts)
    -- Return array of accounts.
    local accounts = {}    

    startPage:xpath("//div[contains(@class, 'module-account')]"):each(
        function(index, element)
            local count, _, accountNumber = string.find(element:xpath(".//div[@class='col5']/p/span"):text(), "xxxx ([%d]+)")
            table.insert(accounts, {
                type = AccountTypeGiro,
                currency = "EUR",
                name = element:xpath(".//h2/a"):text(),
                accountNumber = accountNumber
            })
        end
    )

    return accounts
end

function RefreshAccount(account, since)
    local statementPage = nil
    local balance = nil
    local months = 1

    -- query balance & get statement url
    startPage:xpath("//div[contains(@class, 'module-account')]"):each(
        function(index, element)
            local count, _, accountNumber = string.find(element:xpath(".//div[@class='col5']/p/span"):text(), "xxxx ([%d]+)")

            if accountNumber == account.accountNumber then
                local balanceStr = element:xpath(".//span[@class='fund-1']"):text()
                balanceStr = string.gsub(balanceStr, "€", "")
                balanceStr = string.gsub(balanceStr, ",", "")
                balance = tonumber(balanceStr)
                
                if since < (os.time() - 2592000) then
                    months = 3
                end
                
                local count, _, accountId = string.find(element:xpath(".//h2/a"):attr("href"), ".+accountId=(.+)$")
                statementUrl = '/online/Accounts/Details/RecentTransactions?accountId=' .. accountId .. "&months=" .. months
                statementPage = HTML(connection:request("GET", statementUrl))
             end
        end
    )

    if statementPage == nil then
        error("Could not retrieve statement")
    end

    local transactions = {}

    -- load transactions
    local transactionDetails = statementPage:xpath("//div[contains(@class, 'module-account-detail')]/*/*/tbody")

    transactionDetails:children():each(
        function(index, element)
            local bookingText = nil
            local purpose = nil
            local endToEndReference = nil
        
            local firstElement = element:children():get(1)
            local timestamp = humanDateStrToTimestamp(firstElement:text())

            local descriptionElement = element:children():get(2)
            local description = descriptionElement:text()
            
            if (string.sub(description, 0, 2)) == 'CT' then
                bookingText = 'Credit Transfer'
                description = string.sub(description, 3, -1)
            elseif (string.sub(description, 0, 2)) == 'DD' then
                bookingText = 'Direct Debit'
                description = string.sub(description, 3, -1)
            elseif (string.sub(description, 0, 3)) == 'POS' then
                bookingText = 'Debit Card Transaction'
                description = string.sub(description, 4, -1)
            elseif (string.sub(description, 0, 3)) == 'CNC' then
                bookingText = 'Debit Card Transaction (Contactless)'
                description = string.sub(description, 4, -1)
            elseif (string.sub(description, 0, 3)) == 'ATM' then
                bookingText = 'ATM Transaction'
                description = string.sub(description, 4, -1)
            end
            
            -- Get SEPA details
            local sepaForm = descriptionElement:xpath(".//form")
            if sepaForm:length() > 0 then
                local sepaPage = HTML(connection:request(sepaForm:submit()))
                if sepaPage == nil then
                    error("Could not retrieve SEPA details for " .. firstElement:text() .. " " .. description)
                end
                   local sepaVars = sepaPage:xpath("//div[@class='value']")
                description = sepaVars:get(1):text()
                purpose = sepaVars:get(3):text() .. " " .. sepaVars:get(9):text()
                endToEndReference = sepaVars:get(8):text()
            end
            
            local amount = nil
            local inAmountStr = element:children():get(3):text()
            local outAmountStr = element:children():get(4):text()
            local amountStr
            if string.len(inAmountStr) > 0 then
                amountStr = inAmountStr
            else
                amountStr = "-" .. outAmountStr
            end
            amountStr = string.gsub(amountStr, ",", "")
            amount = tonumber(amountStr)

            table.insert(transactions, {
                name = description,
                bookingDate = timestamp,
                purpose = purpose,
                amount = amount,
                bookingText = bookingText,
                endToEndReference = endToEndReference
            })

        end
    )

    return {balance = balance, transactions = transactions}
end

function EndSession ()
    print(HTML(connection:request("GET", logoutUrl)):xpath("//h1"):text())
end

-- permanent tsb formatting helpers --------------------------------------------------------------------------------------

function humanDateStrToTimestamp(dateStr)
    local dayStr, monthStr, yearStr = string.match(dateStr, "(%d%d) (%u%l%l) (%d%d)")

    local monthDict = {
        Jan = 1,
        Feb = 2,
        Mar = 3,
        Apr = 4,
        May = 5,
        Jun = 6,
        Jul = 7,
        Aug = 8,
        Sep = 9,
        Oct = 10,
        Nov = 11,
        Dec = 12
    }

    return os.time({
        year = 2000 + tonumber(yearStr),
        month = monthDict[monthStr],
        day = tonumber(dayStr)
    })
end
