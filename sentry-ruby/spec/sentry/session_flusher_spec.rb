require "spec_helper"

RSpec.describe Sentry::SessionFlusher do
  let(:string_io) { StringIO.new }

  let(:configuration) do
    Sentry::Configuration.new.tap do |config|
      config.release = 'test-release'
      config.environment = 'test'
      config.transport.transport_class = Sentry::DummyTransport
      config.background_worker_threads = 0
      config.logger = Logger.new(string_io)
    end
  end

  let(:client) { Sentry::Client.new(configuration) }
  let(:transport) { client.transport }
  subject { described_class.new(configuration, client) }

  before do
    Sentry.background_worker = Sentry::BackgroundWorker.new(configuration)
  end

  describe "#initialize" do
    context "when config.release is nil" do
      before { configuration.release = nil }

      it "logs debug message" do
        flusher = described_class.new(configuration, client)

        expect(string_io.string).to match(
          /Sessions won't be captured without a valid release/
        )
      end
    end
  end

  describe "#flush" do
    it "early returns with no pending_aggregates" do
      subject.instance_variable_set(:@pending_aggregates, {})

      expect do
        subject.flush
      end.not_to change { transport.envelopes.count }
    end

    it "captures pending_aggregates in background worker" do
      t1 = Sentry.utc_now
      t1_bucket = Time.utc(t1.year, t1.month, t1.day, t1.hour, t1.min)

      aggregates = { t1_bucket => { exited: 50, errored: 10 } }
      subject.instance_variable_set(:@pending_aggregates, aggregates)

      expect do
        subject.flush
      end.to change { transport.envelopes.count }.by(1)

      envelope = transport.envelopes.first
      expect(envelope.items.length).to eq(1)
      item = envelope.items.first
      expect(item.type).to eq('sessions')
      expect(item.payload[:attrs]).to eq({ release: 'test-release', environment: 'test' })
      expect(item.payload[:aggregates].first).to eq({ exited: 50, errored: 10, started: t1_bucket.iso8601 })
    end
  end

  describe "#add_session" do
    let(:session) do
      session = Sentry::Session.new
      session.close
      session
    end

    context "when config.release is nil" do
      before { configuration.release = nil }

      it "noops" do
        flusher = described_class.new(configuration, client)
        flusher.add_session(session)
        expect(flusher.instance_variable_get(:@pending_aggregates)).to eq({})
      end
    end

    it "spawns new thread" do
      expect do
        subject.add_session(session)
      end.to change { Thread.list.count }.by(1)

      expect(subject.instance_variable_get(:@thread)).to be_a(Thread)
    end

    it "adds session to pending_aggregates" do
      subject.add_session(session)
      pending_aggregates = subject.instance_variable_get(:@pending_aggregates)
      expect(pending_aggregates.keys.first).to be_a(Time)
      expect(pending_aggregates.values.first).to eq({ errored: 0, exited: 1 })
    end
  end
end