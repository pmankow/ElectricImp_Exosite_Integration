// MIT License

// Copyright 2019 Exosite

// SPDX-License-Identifier: MIT

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
// EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
// OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

enum EXOSITE_MODES {
    MURANO_PRODUCT = "EXOSITE_MODE_MURANO_PRODUCT"
    IOT_CONNECTOR = "EXOSITE_MODE_IOT_CONNECTOR"
}

class Exosite {
      static IOT_CONNECTOR_ID = "g2bmsijv2ku800000";
      static VERSION = "1.1.0";

     //set to true to log debug message on the ElectricImp server
     _debugMode             = false;
     //Number of milliseconds to timeout between config_io refreshes. 
     _configIORefreshTimeout   = 15000000; 

     //Private variables
     _baseURL              = null;
     //Common headers for most all requests
     _headers              = {};
     _configIOHeaders      = {};
     _deviceId             = null;
     //ExoSense's config_io includes meta data about the signals
     _configIO             = null;
     //Used to convert a key to the corresponding channel_id in config_io
     _idConversionTable    = null; 
     _productId            = null;
     _mode                 = null;

     // constructor
     // Returns: Nothing
     // Parameters:
     //      mode (reqired) : emun (EXOSITE_MODES) - The mode to run the library in, see README for more info on options.
     //      settings (required) : table - The settings corresponding to the mode being run.
     //
    constructor(mode, settings) {
        _mode = mode;
        _productId = _getProductId(mode, settings);

        _baseURL = format("https://%s.m2.exosite.io/", _productId);

        if (_mode == EXOSITE_MODES.IOT_CONNECTOR) 
            _deviceId = _getDeviceFromURL(http.agenturl());
        else
            _deviceId = (_tableGet(settings, "deviceId") == null) ?  _getDeviceFromURL(http.agenturl()) : settings.deviceId;

        _headers["Content-Type"] <- "application/x-www-form-urlencoded; charset=utf-8";
        _headers["Accept"] <- "application/x-www-form-urlencoded; charset=utf-8";
    }

    //Provision - send a provision HTTP request
    // Returns - Nothing (use callback)
    // Parameters -
    //           callback: function - function to call with http response. This response will contain the Auth token on success
    function provision(callback){
        _debug("Provisioning");
        _debug("headers: " + http.jsonencode(_headers));
        local activate_url = format("%sprovision/activate", _baseURL);
        local data = format("id=%s", _deviceId);
        local req = http.post(activate_url, _headers, data);
        req.sendasync(callback);
    }

    // writeData - Write a table to the "data_in" channel in the Exosite product
    // Returns: Nothing
    // Parameters: 
    //      table (required) : string - The table to be written to "data_in".
    //                                 This table should conform to the config_io for the device.
    //                                 That is, each key should match a channel identifier and the value type should match the channel's data type.
    //            token: string - CIK Authorization token for the device
    //
    // This is anticipated to be the function to call for device.on("reading.sent", <pointer_to_this_function>);
    function writeData(table, token) {
        // The table will remain unchanged if app_specific_config is not used in the config_io
        table = _match_with_config_io(table, _idConversionTable);
        _writeData_w_cb(table, _responseErrorCheck.bindenv(this), token);
    }

    // pollConfigIO - Fetches the config_io from the Exosite server and writes it back. This is how the device acknowledges the config_io
    // Returns: Nothing
    // Parameters:
    //            token: string - CIK Authorization token for the device
    function pollConfigIO(token) {
        _configIOHeaders = clone(_headers);
        _configIOHeaders["X-Exosite-CIK"]  <-  token;

        _configIOLoop();
    }

    // writeConfigIO - Writes a config via http post request
    // Returns: null
    // Parameters:
    //            config_io : string - the config_io to post formatted as "config_io=<config_io_value>"
    //            token: string - CIK Authorization token for the device
    //
    // The config_io is the 'contract' between the device and ExoSense of how the data is going to be transmitted
    // See https://exosense.readme.io/docs/channel-configuration for more information
    function writeConfigIO(config_io, token){
        local configIOHeaders = clone(_headers);
        configIOHeaders["X-Exosite-CIK"]  <-  token;

        // decode/encode combo turns the \" -> " within the config_io to make it correct
        _configIO = http.jsondecode(http.jsonencode(http.urldecode(config_io).config_io));

        server.log("writeConfigIO: " + _configIO);
        _debug("headers: " + http.jsonencode(configIOHeaders));

        server.log("Actual Input: " + _configIO);
        _idConversionTable  = _create_channel_converter_table(_configIO);
        local req = http.post(format("%sonep:v1/stack/alias", _baseURL), configIOHeaders, config_io);
        req.sendasync(_responseErrorCheck.bindenv(this));
    }

    // readAttribute - Fetches the given attribute from the Exosite server. 
    // Returns: None
    // Parameters: 
    //            attribute: string - name of the attribute to get
    //            callback: function - callback for the http response from the get request
    //            token: string - CIK Authorization token for the device
    function readAttribute(attribute, callback, token) {
        local readAttributeHeaders = clone(_headers);
        readAttributeHeaders["X-Exosite-CIK"]  <-  token;
        _debug("fetching attribute: " + attribute);
        _debug("headers: " + http.jsonencode(readAttributeHeaders));

        local req = http.get(format("%sonep:v1/stack/alias?%s", _baseURL, attribute), readAttributeHeaders);
        req.sendasync(callback.bindenv(this));
    }

    //setDebugMode - Turns on or off extra logging to the server, defaults to off/false
    // Returns - None
    // Parameters:
    //          value: boolean - True = enable extra logging
    function setDebugMode(value) {
        _debugMode = value;
    }

    //setConfigIORefreshTimeout - Changes the timeout length for a configIO long poll, defaults to 15000000 ms
    // Returns - None
    // Parameters:
    //           val_milliseconds: integer - number of milliseconds before timing out the config_io long poll
    function setConfigIORefreshTimeout(val_milliseconds) {
        _configIORefreshTimeout = val_milliseconds;
    }

    //=======================================================
    //       PRIVATE FUNCTIONS
    //=======================================================

    //Private function that makes checking a table entry easier
    // Returns: value if it exists
    //          null if it doesn't exist (or is null)
    // Parameters 
    //           table: table - table to check
    //           index: string - index to check
    function _tableGet(table, index) {
        if (!table.rawin(index)) {
            return null;
        }
        return table[index];
    }

    //Private function to assist in different modes
    // Returns: string - the productId to connect to
    // Parameters: 
    //             mode: string - name of the mode being used
    //             settings: table - table of settings, required if the deviceId is expected to be in the settings table
    function _getProductId(mode, settings) {
        local productId = null;

        switch (mode) {
            case EXOSITE_MODES.MURANO_PRODUCT:
                productId = _tableGet(settings, "productId");
                if (productId == null) {
                    server.error("Mode MuranoProduct requires a productId in settings");
                }
                break;
            case EXOSITE_MODES.IOT_CONNECTOR:
                productId = IOT_CONNECTOR_ID;
                break;
            default:
                server.error("No product ID found");
        }

        return productId;
    }

    //Private Helper function to get unique ID from each device
    // Returns: ElectricImps AgentID (Unique per device)
    // Parameters:
    //         urlString: string - The agent's URL. This can be retrieved via http.agenturl()
    function _getDeviceFromURL(urlString) {
        local splitArray = split(urlString, "/");
        local lastEntry = splitArray.top();
        return lastEntry;
    }

    // debug - prints out to server.log if the debug flag is true
    // Returns: Nothing
    // Parameters:
    //           logVal: string - The value to log to server if _debugMode flag is set.
    function _debug(logVal) {
        if (_debugMode) {
            server.log(logVal);
        }
    }

    //Private Helper function to create an easy lookup table for converting between the keys here and ExoSense's channel_ids
    //    - This allows the user to define the keys (in the key-value pair) that the device uses, since the channel_id is arbitrarily assigned from ExoSense
    //           This is done with app_specific_config in the channel creation
    //    - If the app_specific_config is not used, the user must use the channel_ids generated by ExoSense directly...this will then be empty and effectively unused
    // Returns: A table that includes associated device keys as the "key" and ExoSense's keys as the "value"
    // Parameters:
    //         configIOString: string - The config_io that ExoSense is using to interpret the data_in signal
    function  _create_channel_converter_table(configIOString) {
        local return_table = {}
        local config_table = http.jsondecode(configIOString);
        server.log(http.jsonencode(config_table));
        foreach (key, channel in config_table.channels) {
            if ("protocol_config" in channel
                && "app_specific_config" in channel.protocol_config
                && "application" in channel.protocol_config
                && channel.protocol_config.application == "ElectricImp"
                && "key" in channel.protocol_config.app_specific_config) {
                local local_key = channel.protocol_config.app_specific_config.key;
                return_table[local_key] <- key;
            } 
        }

        return return_table;
    }

    //Private Helper function to transform the data_in signals to use known channel_ids from ExoSense
    // 
    // Returns: A table that modified the keys of the data_table to match ExoSense instead of the device's key-value pair
    // Parameters:
    //         data_table: table - a key-value pair of data sent from the device
    //         id_conversion_table: table - a table associating local device data keys as the "key" and ExoSense channel_ids as the "value"
    //    
    // id_conversion_table can be generated from a config_io string using the `_create_channel_converter_table` function
    //
    // Warning, this modifies the table provided.
    // It also returns it for readability
    function _match_with_config_io(data_table, id_conversion_table) {
        local converted_data_table = {};
            foreach (key, value in data_table) {
                if (key in id_conversion_table)
                    converted_data_table[id_conversion_table[key]] <- value;
                else {
                    if(key in converted_data_table)
                        server.log("WARNING: Repeat channel ID, dropping data");
                    else
                        converted_data_table[key] <- value;
                }
            }
        return converted_data_table;
    }
    
    //Private Function
    // this is here to assist in testing, otherwise we would just have the writeData() function
    // Returns: Nothing
    // Parameters: 
    //      table (required) : string - The table to be written to "data_in".
    //                                 This table should conform to the config_io for the device.
    //                                 That is, each key should match a channel identifier and the value type should match the channel's data type.
    //      callback (required) : function - callback function for the http write request
    function _writeData_w_cb(table, callback, token){
        local writeDataHeaders = clone(_headers);
        writeDataHeaders["X-Exosite-CIK"]  <-  token;
        _debug("writeData: " + http.jsonencode(table));
        _debug("headers: " + http.jsonencode(_headers));

        local jsonString = http.jsonencode(table);
        local postBody = http.urlencode({ "data_in" : jsonString });  // no space in key
        local req = http.post(format("%sonep:v1/stack/alias", _baseURL), writeDataHeaders, postBody);
        req.sendasync(callback.bindenv(this));
    }

    function _configIOLoop() {
        if (_configIO != null) {
            //Long Poll for a change if we already have one. Else, just grab it
            _configIOHeaders["Request-Timeout"] <- _configIORefreshTimeout;
        }
        _debug("fetching config_io");
        _debug("headers: " + http.jsonencode(_configIOHeaders));

        local req = http.get(format("%sonep:v1/stack/alias?config_io", _baseURL), _configIOHeaders);
        req.sendasync(_pollConfigIOCallback.bindenv(this));
    }

    // pollConfigIOCallback - Callback for the pollConfigIO request
    // Returns: null
    // Parameters:
    //             response - the response object for the http request
    //
    // This is split from having writeConfigIO be the callback directly so that a user can write their own string via writeConfigIO.
    function _pollConfigIOCallback(response) {
        _debug("Server Response: \n");
        _debug(response.statuscode + "\n");
        _debug(response.body + "\n");
        if (response.statuscode == 200){
            writeConfigIO(response.body, _configIOHeaders["X-Exosite-CIK"]);
        } else if (response.statuscode == 204) {
            _configIO = "";
        }else if (response.statuscode == 304) {
            _debug("config_io not modified, not writing back");
        } else {
            server.error ("Error in _pollConfigIOCallback, ResponseCode: " + response.statuscode + response.body);
            //Return and stop the loop
            return;
        }

        imp.wakeup(0.0, _configIOLoop.bindenv(this));
    }

    // responseErrorCheck - Checks the status code of an http response and prints to the server log
    // Returns: The response's status code
    // Parameters:
    //            - response : object - response object from the http request
    function _responseErrorCheck(response) {
        // 200 - Ok           - Successful Request, returning requested values
        // 204 - No Content   - Successful Request, nothing will be returned
        // 4xx - Client Error - There was an error with the request by the client
        // 409 - Conflict     - (Example: Provisioning a provisioned device)
        // 401 - Unauthorized - Missing or Invalid Credentials
        // 415 - Unsupported media type - missing header
        // 5xx - Server Error - Unhandled server error. Contact Support
        _debug("Server Response: \n");
        _debug(response.statuscode + "\n");
        _debug(response.body + "\n");

        return response.statuscode;
    }
}
