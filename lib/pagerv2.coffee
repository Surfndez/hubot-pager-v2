# Description:
#   handles communication with PagerDuty API v2
#
# Dependencies:
#
# Configuration:
#  PAGERV2_API_KEY
#  PAGERV2_SCHEDULE_ID       # the schedule used for oncall and overrides
#  PAGERV2_OVERRIDERS        # list of user_id that can be targets of overrides
#  PAGERV2_SERVICES          # list of services that are concerned by massive maintenance
#  PAGERV2_DEFAULT_RESOLVER  # name of the default user for resolution (ex. nagios)
#  PAGERV2_LOG_PATH          # dir where are saved error logs
#
# Author:
#   mose

fs = require 'fs'
path = require 'path'
https = require 'https'
moment = require 'moment'
Promise = require 'bluebird'
querystring = require 'querystring'


class Pagerv2

  constructor: (@robot) ->
    @robot.brain.data.pagerv2 ?= {
      users: { },
      services: { }
    }
    @pagerServices = [ ]
    if process.env.PAGERV2_SERVICES?
      for service in process.env.PAGERV2_SERVICES.split(',')
        @pagerServices.push(service)
    @logger = @robot.logger
    @logger.debug 'Pagerv2 Loaded'
    if process.env.PAGERV2_LOG_PATH?
      @errorlog = path.join process.env.PAGERV2_LOG_PATH, 'pagerv2-error.log'

  getPermission: (user, group) =>
    return new Promise (res, err) =>
      isAuthorized = @robot.auth?.hasRole(user, [group, 'pageradmin']) or
                     @robot.auth?.isAdmin(user)
      if process.env.PAGERV2_NEED_GROUP_AUTH? and
         process.env.PAGERV2_NEED_GROUP_AUTH isnt '0' and
         @robot.auth? and
         not(isAuthorized)
        err "You don't have permission to do that."
      else
        res()

  request: (method, endpoint, query, from = false) ->
    return new Promise (res, err) ->
      if process.env.PAGERV2_API_KEY?
        auth = "Token token=#{process.env.PAGERV2_API_KEY}"
        body = querystring.stringify(query)
        if method is 'GET' and body isnt ''
          endpoint += "?#{body}"
        options = {
          hostname: 'api.pagerduty.com'
          port: 443
          method: method
          path: endpoint
          headers: {
            Authorization: "#{auth}",
            Accept: 'application/vnd.pagerduty+json;version=2'
          }
        }
        if from?
          options.headers.From = from
        req = https.request options, (response) ->
          data = []
          response.on 'data', (chunk) ->
            data.push chunk
          response.on 'end', ->
            json_data = JSON.parse(data.join(''))
            if json_data.error?
              err "#{json_data.error.code} #{json_data.error.message}"
            else
              res json_data
        req.on 'error', (error) ->
          err "#{error.code} #{error.message}"
        if method is 'PUT' or method is 'POST'
          req.write body
        req.end()
      else
        err 'PAGERV2_API_KEY is not set in your environment.'

  getUser: (from, user) =>
    return new Promise (res, err) =>
      unless user.id?
        user.id = user.name
      if @robot.brain.data.pagerv2.users[user.id]?.pagerid?
        res @robot.brain.data.pagerv2.users[user.id].pagerid
      else
        @robot.brain.data.pagerv2.users[user.id] ?= {
          name: user.name,
          id: user.id
        }
        email = @robot.brain.data.pagerv2.users[user.id].email or user.email_address
        unless email
          err @_ask_for_email(from, user)
        else
          user = @robot.brain.data.pagerv2.users[user.id]
          query = { 'query': email }
          @request('GET', '/users', query)
          .then (body) =>
            if body.users[0]?
              @robot.brain.data.pagerv2.users[user.id].pagerid = body.users[0].id
              res body.users[0].id
            else
              err "Sorry, I cannot find #{email}"

  getUserEmail: (from, user) ->
    return new Promise (res, err) =>
      unless user.id?
        user.id = user.name
      email = @robot.brain.data.pagerv2.users[user.id]?.email or user.email_address
      if email?
        res email
      else
        err @_ask_for_email(from, user)

  setUser: (user, email) =>
    return new Promise (res, err) =>
      unless user.id?
        user.id = user.name
      @robot.brain.data.pagerv2.users[user.id] ?= {
        name: user.name,
        email: email,
        id: user.id
      }
      user = @robot.brain.data.pagerv2.users[user.id]
      query = { 'query': email }
      @request('GET', '/users', query)
      .then (body) =>
        if body.users[0]?
          @robot.brain.data.pagerv2.users[user.id].pagerid = body.users[0].id
          @robot.brain.data.pagerv2.users[user.id].email = email
          res body.users[0].id
        else
          err "Sorry, I cannot find #{email}"
      .catch (e) ->
        err e

  _ask_for_email: (from, user) ->
    if from.name is user.name
      "Sorry, I can't figure out your email address :( " +
      'Can you tell me with `.pager me as <email>`?'
    else
      if @robot.auth? and (@robot.auth.hasRole(from, ['pageradmin']) or
         @robot.auth.isAdmin(from))
        "Sorry, I can't figure #{user.name} email address. " +
        "Can you help me with `.pager #{user.name} as <email>`?"
      else
        "Sorry, I can't figure #{user.name} email address. " +
        'Can you ask them to `.pager me as <email>`?'

  # getSchedule: (
  #   filter = false,
  #   fromtime = false,
  #   totime = false,
  #   schedule_id = process.env.PAGERV2_SCHEDULE_ID
  # ) ->
  #   query = {
  #     since: fromtime or moment().utc().format(),
  #     until: totime or moment().utc().add(1, 'minutes').format(),
  #     time_zone: 'UTC'
  #   }
  #   @request('GET', "/schedules/#{schedule_id}", query)
  #   .then (body) ->
  #     # console.log body.schedule
  #     body.schedule.final_schedule.rendered_schedule_entries[0]

  getOverride: (schedule_id = process.env.PAGERV2_SCHEDULE_ID) ->
    query = {
      since: moment().format(),
      until: moment().add(1, 'minutes').format(),
      editable: 'true',
      overflow: 'true'
    }
    @request('GET', "/schedules/#{schedule_id}/overrides", query)
    .then (body) ->
      body.overrides

  getOncall: (fromtime = null, schedule_id = process.env.PAGERV2_SCHEDULE_ID) ->
    query = {
      time_zone: 'UTC',
      'schedule_ids[]': schedule_id,
      earliest: 'true'
    }
    if fromtime?
      query['since'] = moment(fromtime).utc().add(1, 'minutes').format()
      query['until'] = moment(fromtime).utc().add(2, 'minutes').format()
    @request('GET', '/oncalls', query)
    .then (body) ->
      body.oncalls[0]

  setOverride: (from, who, duration = null) ->
    return new Promise (res, err) =>
      if duration? and duration > 1440
        err 'Sorry you cannot set an override of more than 1 day.'
      else
        schedule_id = process.env.PAGERV2_SCHEDULE_ID
        overriders = process.env.PAGERV2_OVERRIDERS?.split(',')
        if not who? or who is 'me'
          who = { name: from.name }
        else
          if overriders and who not in overriders
            unless @robot.auth? and
               (@robot.auth.hasRole(from, ['pageradmin']) or @robot.auth.isAdmin(from))
              who = null
              err "You cannot force #{who.name} to take the override."
        if who?
          @getUser(from, who)
          .bind({ id: null })
          .then (id) =>
            @id = id
            @getOncall()
          .then (data) =>
            query  = {
              'start': moment().format(),
              'user': {
                'id': @id,
                'type': 'user_reference'
              }
            }
            if duration?
              duration = parseInt duration
              query.end = moment().add(duration, 'minutes').format()
            else
              query.end = moment(data.end)
            # TODO - with user on call, res a relevant message
            @request('POST', "/schedules/#{schedule_id}/overrides", query)
            .then (body) ->
              body.override.over = {
                name: who.name
              }
              res body.override
            .catch (error) ->
              err error
          .catch (error) ->
            err error

  dropOverride: (from, who) ->
    return new Promise (res, err) =>
      schedule_id = process.env.PAGERV2_SCHEDULE_ID
      if not who? or who is 'me'
        who = { name: from.name }
      else
        if overriders and who not in overriders
          unless @robot.auth? and
             (@robot.auth.hasRole(from, ['pageradmin']) or @robot.auth.isAdmin(from))
            who = null
            err "You cannot force #{who.name} to take the override."
      if who?
        @getUser(from, who)
        .bind({ id: null })
        .then (id) =>
          @id = id
          @getOverride()
        .then (data) =>
          todo = null
          for over in data
            if over.user.id is @id
              todo = over.id
          if todo?
            @request('DELETE', "/schedules/#{schedule_id}/overrides/#{todo}")
            .then (data) ->
              res data
            .catch (e) ->
              err e
          else
            res null

  getIncident: (incident) ->
    @request('GET', "/incidents/#{incident}")

  listIncidents: (
    incidents = '',
    statuses = 'triggered,acknowledged',
    date_since = null,
    date_until = null,
    limit = 100
  ) ->
    if incidents isnt ''
      new Promise (res, err) ->
        res {
          incidents: incidents.split(/[, ]+/).map (inc) ->
            { id: inc }
          }
    else
      query = {
        time_zone: 'UTC',
        'include[]': 'first_trigger_log_entry'
      }
      if date_since?
        unless date_until?
          date_until = moment().utc()
        query['date_since'] = moment(date_since).format()
        query['date_until'] = moment(date_until).format()
      else
        query['date_range'] = 'all'
      if statuses?
        query['statuses[]'] = statuses.split /,/
      query['limit'] = limit
      query['total'] = 'true'
      @request('GET', '/incidents', query)
      .then (data) ->
        data

  upagerateIncidents: (user, incidents = '', which = 'triggered', status = 'acknowledged') ->
    @getUserEmail(user, user)
    .bind({ from: null })
    .then (email) =>
      @from = email
      @listIncidents incidents, which
    .then (data) =>
      if data.incidents.length > 0
        payload = {
          incidents: []
        }
        for inc in data.incidents
          payload.incidents.push {
            id: inc.id,
            type: 'incident_reference',
            status: status
          }
        @request('PUT', '/incidents', payload, @from)
      else
        throw { message: "There is no #{which} incidents at the moment." }

  assignIncidents: (user, who, incidents = '') ->
    @getUserEmail(user, user)
    .bind({ from: null })
    .bind({ assignees: null })
    .then (email) =>
      @from = email
      assigneesDone = Promise.map who.split(/, ?/), (assignee) =>
        @getUser(user, { name: assignee })
      Promise.all assigneesDone
    .then (assignees) =>
      @assignees = assignees
      @listIncidents incidents
    .then (data) =>
      if data.incidents.length > 0
        payload = {
          incidents: []
        }
        for inc in data.incidents
          payload.incidents.push {
            id: inc.id,
            type: 'incident_reference',
            assignments: []
          }
          for a in @assignees
            payload.incidents.push {
              id: a,
              type: 'user_reference'
            }
        @request('PUT', '/incidents', payload, @from)
      else
        throw { message: 'There is no incidents at the moment.' }

  snoozeIncidents: (user, incidents = '', duration = 120) ->
    @getUserEmail(user, user)
    .bind({ from: null })
    .then (email) =>
      @from = email
      @listIncidents incidents
    .then (data) =>
      if data.incidents.length > 0
        incidentsDone = Promise.map data.incidents, (inc) =>
          payload = {
            duration: duration
          }
          @request('POST', "/incidents/#{inc.id}/snooze", payload, @from)
        Promise.all incidentsDone
      else
        throw { message: 'There is no open incidents at the moment.' }

  addNote: (user, incident, note) ->
    @getUserEmail(user, user)
    .then (email) =>
      payload = {
        note: {
          content: note
        }
      }
      @request('POST', "/incidents/#{incident}/notes", payload, email)

  listNotes: (incident) ->
    @request('GET', "/incidents/#{incident}/notes")

  listMaintenances: ->
    query = {
      filter: 'ongoing'
    }
    @request('GET', '/maintenance windows', query)

  addMaintenance: (user, duration, description) ->
    @getUserEmail(user, user)
    .bind(@email)
    .then (email) =>
      @email = email
      service_ids = Promise.map @pagerServices, (service) =>
        @serviceId(service)
      Promise.all(service_ids)
    .then (service_ids) =>
      payload = {
        maintenance_window: {
          type: 'maintenance_window',
          start_time: moment().format(),
          end_time: moment().add(duration, 'minutes').format(),
          description: description or 'Maintenance in progress.',
          services: [ ]
        }
      }
      for service in service_ids
        payload.maintenance_window.services.push {
          id: service,
          type: 'service_reference'
        }
      @request('POST', '/maintenance windows', payload, @email)

  endMaintenance: (user, id) ->
    @request('DELETE', "/maintenance windows/#{id}", { })

  coloring: {
    irc: (text, color) ->
      colors = require('irc-colors')
      if colors[color]
        colors[color](text)
      else
        text

    slack: (text, color) ->
      "*#{text}*"

    generic: (text, color) ->
      text
  }

  getService: (name) ->
    payload = {
      query: name
    }
    @request('GET', '/services', payload)

  serviceId: (name) ->
    new Promise (res, err) =>
      if @robot.brain.data.pagerv2.services[name]?
        res @robot.brain.data.pagerv2.services[name]
      else
        @getService(name)
        .then (payload) =>
          @robot.brain.data.pagerv2.services[name] = payload.services[0].id
          res @robot.brain.data.pagerv2.services[name]

  parseWebhook: (adapter, messages) ->
    new Promise (res, err) =>
      colors = {
        trigger: 'red',
        unacknowledge: 'red',
        acknowledge: 'yellow',
        resolve: 'green',
        assign: 'blue',
        escalate: 'blue'
      }
      res messages.map (message) =>
        level = message.type.substring(message.type.indexOf('.') + 1)
        if @coloring[adapter]?
          colorer = @coloring[adapter]
        else
          colorer = @coloring.generic
        origin = colorer(
          "[#{message.data.incident.service.name}]",
          colors[level]
        )
        description = message.data.incident.trigger_summary_data.subject
        who = if message.type is 'incident.resolve' and message.data.incident.resolved_by_user?
                message.data.incident.resolved_by_user.name
              else if message.data.incident.assigned_to_user?
                message.data.incident.assigned_to_user.name
              else
                process.env.PAGERV2_DEFAULT_RESOLVER or 'nagios'
        id = message.data.incident.id
        number = message.data.incident.incident_number
        "#{origin} #{id} [##{number}] #{description} - #{level} (#{who})"

  colorer: (adapter, level, text) ->
    colors = {
      trigger: 'red',
      triggered: 'red',
      unacknowledge: 'red',
      unacknowledged: 'red',
      acknowledge: 'yellow',
      acknowledged: 'yellow',
      resolve: 'green',
      resolved: 'green',
      assign: 'blue',
      escalate: 'blue'
    }
    if @coloring[adapter]?
      @coloring[adapter](text, colors[level])
    else
      @coloring.generic(text, colors[level])

  logError: (message, payload) ->
    if @errorlog?
      fs.appendFileSync @errorlog, '\n---------------------\n'
      fs.appendFileSync @errorlog, "#{moment().utc().format()} - #{message}\n\n"
      fs.appendFileSync @errorlog, JSON.stringify(payload, null, 2), 'utf-8'



module.exports = Pagerv2
