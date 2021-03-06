# frozen_string_literal: true

# lita-jira plugin
module Lita
  # Because we can.
  module Handlers
    # Main handler
    # rubocop:disable Metrics/ClassLength
    class Jira < Handler
      namespace 'Jira'

      config :username, required: true, type: String
      config :password, required: true, type: String
      config :site, required: true, type: String
      config :context, required: false, type: String, default: ''
      config :format, required: false, type: String, default: 'verbose'
      config :ambient, required: false, types: [TrueClass, FalseClass], default: false
      config :ignore, required: false, type: Array, default: []
      config :rooms, required: false, type: Array
      config :use_ssl, required: false, types: [TrueClass, FalseClass], default: true
      config :points_field, required: false, type: String

      include ::JiraHelper::Issue
      include ::JiraHelper::Misc
      include ::JiraHelper::Regex
      include ::JiraHelper::Utility

      route(
        /^jira\s#{ISSUE_PATTERN}$/,
        :summary,
        command: true,
        help: {
          t('help.summary.syntax') => t('help.summary.desc')
        }
      )

      route(
        /^jira\sdetails\s#{ISSUE_PATTERN}$/,
        :details,
        command: true,
        help: {
          t('help.details.syntax') => t('help.details.desc')
        }
      )

      route(
        /^jira\smyissues$/,
        :myissues,
        command: true,
        help: {
          t('help.myissues.syntax') => t('help.myissues.desc')
        }
      )

      route(
        /^jira\scomment\son\s#{ISSUE_PATTERN}\s#{COMMENT_PATTERN}$/,
        :comment,
        command: true,
        help: {
          t('help.comment.syntax') => t('help.comment.desc')
        }
      )

      route(
        /^todo\s#{PROJECT_PATTERN}\s#{SUBJECT_PATTERN}\s#{SUMMARY_PATTERN}$/,
        :todo,
        command: true,
        help: {
          t('help.todo.syntax') => t('help.todo.desc')
        }
      )

      # At the moment this can crash the bot, so remove it until it is fixed.
      #route(
      #  /^jira\spoint\s#{ISSUE_PATTERN}\sas\s#{POINTS_PATTERN}$/,
      #  :point,
      #  command: true,
      #  help: {
      #    t('help.point.syntax') => t('help.point.desc')
      #  }
      #)

      # Detect ambient JIRA issues in non-command messages
      route AMBIENT_PATTERN, :ambient, command: false

      def get_slack_api(api_call)
        api_response = HTTParty.get(
          "https://slack.com/api/#{api_call}?token=#{robot.config.adapters.slack.token}&pretty=0"
        )
        data = MultiJson.load(api_response.body)
        if data["ok"] == true
          return data
        else
          return {}
        end
      end

      def summary(response)
        issue = fetch_issue(response.match_data['issue'])
        return response.reply(t('error.request')) unless issue
        response.reply(t('issue.summary', key: "#{config.site}#{config.context}browse/#{issue.key}", summary: issue.summary))
      end

      def details(response)
        issue = fetch_issue(response.match_data['issue'])
        return response.reply(t('error.request')) unless issue
        response.reply(format_issue(issue))
      end

      def comment(response)
        issue = fetch_issue(response.match_data['issue'])
        return response.reply(t('error.request')) unless issue
        comment = issue.comments.build
        comment.save!(body: response.match_data['comment'])
        response.reply(t('comment.added', issue: "#{config.site}#{config.context}browse/#{issue.key}"))
      end

      def todo(response)
        team_data = get_slack_api("team.info")
        team_domain = team_data['team']['domain']
        if team_domain == 'datanerd-staging'
          project = 'TEST'
        else
          project = response.match_data['project']
        end
        issue = create_issue(project,
                             response.match_data['subject'],
                             response.match_data['summary'],
                             response.user)
        return response.reply(t('error.request')) unless issue
        response.reply(t('issue.created', key: "#{config.site}#{config.context}browse/#{issue.key}"))
      end

      # rubocop:disable Metrics/AbcSize
      def point(response)
        return response.reply(t('error.field_undefined')) if config.points_field.blank?
        issue = fetch_issue(response.match_data['issue'])
        return response.reply(t('error.request')) unless issue
        set_points_on_issue(issue, response)
      end

      def myissues(response)
        return response.reply(t('error.not_identified')) unless user_stored?(response.user)

        begin
          issues = fetch_issues("assignee = '#{get_email(response.user)}' AND status not in (Closed)")
        rescue StandardError => e
          log.error("JIRA HTTPError #{e}")
          response.reply(t('error.request'))
          return
        end

        return response.reply(t('myissues.empty')) if issues.empty?

        response.reply(format_issues(issues))
      end

      def ambient(response)
        return if invalid_ambient?(response)

        # response.matches returns an array of array of strings, where the inner arrays are [issue, project]
        # (e.g. [["XYZ-123", "XYZ"]]). We map it into an array of issues (["XYZ-123"]).
        issue_keys = response.matches.map { |match| match[0] }

        if issue_keys.length > 1
          # Note that if any of the issue keys do not exist in JIRA, then an exception is thrown and no results are returned.
          # A JIRA 'suggestion' has been filed to allow partial results: https://jira.atlassian.com/browse/JRASERVER-40245
          jql = "key in (#{issue_keys.join(',')})"
          # Exceptions are suppressed and no results are returned since this is just ambient parsing and we do not want
          # the bot to pop up with error messages when an explicit command was not requested.
          issues = fetch_issues(jql, true)
          response.reply(format_issues(issues)) if issues && !issues.empty?
        else
          # Only one issue key was parsed, so directly fetch the one issue.
          issue = fetch_issue(response.match_data['issue'], false)
          response.reply(format_issue(issue)) if issue
        end
      end

      private

      def invalid_ambient?(response)
        response.message.command? || !config.ambient || ignored?(response.user) || (config.rooms && !config.rooms.include?(response.message.source.room))
      end

      def ignored?(user)
        config.ignore.include?(user.id) || config.ignore.include?(user.mention_name) || config.ignore.include?(user.name)
      end

      def set_points_on_issue(issue, response)
        points = response.match_data['points']
        begin
          issue.save!(fields: { config.points_field.to_sym => points.to_i })
        rescue StandardError
          return response.reply(t('error.unable_to_point'))
        end
        response.reply(t('point.added', issue: "#{config.site}#{config.context}browse/#{issue.key}", points: points))
      end
      # rubocop:enable Metrics/AbcSize
    end
    # rubocop:enable Metrics/ClassLength
    Lita.register_handler(Jira)
  end
end
