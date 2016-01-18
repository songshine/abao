async = require 'async'
_ = require 'underscore'
csonschema = require 'csonschema'
glob = require 'glob'
fs = require 'fs'

parseSchema = (source) ->
  if source.contains('$schema')
    #jsonschema
    # @response.schema = JSON.parse @response.schema
    JSON.parse source
  else
    csonschema.parse source
    # @response.schema = csonschema.parse @response.schema

parseHeaders = (raml) ->
  return {} unless raml

  headers = {}
  for key, v of raml
    headers[key] = v.example

  headers

parseFolderPath = (path, method) ->
  method = method.toLowerCase()
  path = path.replace(/\{.+\}$/, 'detail')
  [path.replace(/\/\{.+?\}/g, ''), method.toLowerCase()].join('/')

addCases = (tests, path, method, testFactory, callback, baseTestFolder) ->
  caseFolder = baseTestFolder + parseFolderPath(path, method)

  glob("#{caseFolder}/*.json", (err, files) ->

    callback() if not files.length or err
    if not err
      files.forEach((file) ->
        json = fs.readFileSync(file, 'utf-8')
        definition = JSON.parse json

        # Append new test to tests
        test = testFactory.create()
        tests.push test
        test.name = "Case: #{method} #{path} -> #{definition.response.status}"
        test.isCase = true

        test.request.path = path
        test.request.method = method
        test.request.params = definition.params or {}
        test.request.query = definition.query or {}
        test.request.body = definition.body or {}
        test.request.headers = definition.headers or {}
        # Use json as default content type
        if not test.request.headers['Content-Type']
          test.request.headers['Content-Type'] = 'application/json'

        test.response = definition.response

        callback()
      )
  )

addPositiveCase = (tests, api, path, method, params, testFactory) ->
  for status, res of api.responses
    # Only keep success status code for positive validation by default
    statusInt = parseInt(status)
    continue if statusInt < 200 or statusInt >= 300

    # Append new test to tests
    test = testFactory.create()
    tests.push test

    # Update test
    test.name = "#{method} #{path} -> #{status}"

    # Update test.request
    test.request.path = path
    test.request.method = method
    test.request.headers = parseHeaders(api.headers)
    if api.body?['application/json']
      test.request.headers['Content-Type'] = 'application/json'
      try
        test.request.body = JSON.parse api.body['application/json']?.example
      catch
        console.warn "invalid request example of #{test.name}"
    test.request.params = params

    # Update test.response
    test.response.status = status
    test.response.schema = null
    if (res?.body?['application/json']?.schema)
      test.response.schema = parseSchema res.body['application/json'].schema


addTests = (raml, tests, parent, callback, testFactory, baseCaseFolder) ->

  # Handle 3th optional param
  if _.isFunction(parent)
    baseCaseFolder = testFactory
    testFactory = callback
    callback = parent
    parent = null

  # TODO: Make it a configuration
  baseCaseFolder = 'test' if not baseCaseFolder

  return callback() unless raml.resources

  # Iterate endpoint
  async.each raml.resources, (resource, callback) ->
    path = resource.relativeUri
    params = {}

    # Apply parent properties
    if parent
      path = parent.path + path
      params = _.clone parent.params

    # Setup param
    if resource.uriParameters
      for key, param of resource.uriParameters
        params[key] = param.example

    # In case of issue #8, resource does not define methods
    resource.methods ?= []

    # Iterate response method
    async.each resource.methods, (api, callback) ->
      method = api.method.toUpperCase()

      async.waterfall [
        (callback) ->
          # Find cases sample in test folder (callback is called when case files loaded and case added)
          addCases tests, path, method, testFactory, callback, baseCaseFolder
        ,
        (callback) ->
          # Add positive case based on the 200 status code definition in raml
          addPositiveCase tests, api, path, method, params, testFactory
          callback()
        ,
      ], callback

    , (err) ->
      return callback(err) if err

    # Add all tests for a resource path
    addTests resource, tests, {path, params}, callback, testFactory, baseCaseFolder
  , callback


module.exports = addTests
