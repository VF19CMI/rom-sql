require 'virtus'

RSpec.describe 'Commands / Create' do
  include_context 'relations'

  let(:users) { commands[:users] }
  let(:tasks) { commands[:tasks] }

  before do
    class Params
      include Virtus.model

      attribute :name

      def self.[](input)
        new(input)
      end
    end

    conn.add_index :users, :name, unique: true

    configuration.commands(:users) do
      define(:create) do
        input Params

        validator -> tuple {
          raise ROM::CommandError, 'name cannot be empty' if tuple[:name] == ''
        }

        result :one
      end

      define(:create_many, type: :create) do
        result :many
      end
    end

    configuration.commands(:tasks) do
      define(:create)
    end
  end

  describe '#transaction' do
    it 'creates record if nothing was raised' do
      result = users.create.transaction {
        users.create.call(name: 'Jane')
      }

      expect(result.value).to eq(id: 1, name: 'Jane')
    end

    it 'creates multiple records if nothing was raised' do
      result = users.create.transaction {
        users.create_many.call([{ name: 'Jane' }, { name: 'Jack' }])
      }

      expect(result.value).to match_array([
        { id: 1, name: 'Jane' }, { id: 2, name: 'Jack' }
      ])
    end

    it 'allows for nested transactions' do
      result = users.create.transaction {
        users.create.transaction {
          users.create.call(name: 'Jane')
        }
      }

      expect(result.value).to eq(id: 1, name: 'Jane')
    end

    it 'creates nothing if command error was raised' do
      expect {
        passed = false

        result = users.create.transaction {
          users.create.call(name: 'Jane')
          users.create.call(name: '')
        } >-> _value {
          passed = true
        }

        expect(result.value).to be(nil)
        expect(result.error.message).to eql('name cannot be empty')
        expect(passed).to be(false)
      }.to_not change { container.relations.users.count }
    end

    it 'creates nothing if rollback was raised' do
      expect {
        passed = false

        result = users.create.transaction {
          users.create.call(name: 'Jane')
          users.create.call(name: 'John')
          raise ROM::SQL::Rollback
        } >-> _value {
          passed = true
        }

        expect(result.value).to be(nil)
        expect(result.error).to be(nil)
        expect(passed).to be(false)
      }.to_not change { container.relations.users.count }
    end

    it 'creates nothing if constraint error was raised' do
      expect {
        begin
          passed = false

          users.create.transaction {
            users.create.call(name: 'Jane')
            users.create.call(name: 'Jane')
          } >-> _value {
            passed = true
          }
        rescue => error
          expect(error).to be_instance_of(ROM::SQL::UniqueConstraintError)
          expect(passed).to be(false)
        end
      }.to_not change { container.relations.users.count }
    end

    it 'creates nothing if anything was raised in any nested transaction' do
      expect {
        expect {
          users.create.transaction {
            users.create.call(name: 'John')
            users.create.transaction {
              users.create.call(name: 'Jane')
              raise Exception
            }
          }
        }.to raise_error(Exception)
      }.to_not change { container.relations.users.count }
    end
  end

  it 'uses relation schema for the default input handler' do
    configuration.relation(:users) do
      register_as :users_with_schema

      schema do
        attribute :id, ROM::SQL::Types::Serial
        attribute :name, ROM::SQL::Types::String
      end
    end

    configuration.commands(:users_with_schema) do
      define(:create) do
        result :one
      end
    end

    create = container.commands[:users_with_schema][:create]

    expect(create.input[foo: 'bar', id: 1, name: 'Jane']).to eql(
      id: 1, name: 'Jane'
    )
  end

  it 'returns a single tuple when result is set to :one' do
    result = users.try { users.create.call(name: 'Jane') }

    expect(result.value).to eql(id: 1, name: 'Jane')
  end

  it 'returns tuples when result is set to :many' do
    result = users.try do
      users.create_many.call([{ name: 'Jane' }, { name: 'Jack' }])
    end

    expect(result.value.to_a).to match_array([
      { id: 1, name: 'Jane' }, { id: 2, name: 'Jack' }
    ])
  end

  it 're-raises not-null constraint violation error' do
    expect {
      users.try { users.create.call(name: nil) }
    }.to raise_error(ROM::SQL::NotNullConstraintError)
  end

  it 're-raises uniqueness constraint violation error' do
    expect {
      users.try {
        users.create.call(name: 'Jane')
      } >-> user {
        users.try { users.create.call(name: user[:name]) }
      }
    }.to raise_error(ROM::SQL::UniqueConstraintError)
  end

  it 're-raises check constraint violation error' do
    expect {
      users.try {
        users.create.call(name: 'J')
      }
    }.to raise_error(ROM::SQL::CheckConstraintError, /name/)
  end

  it 're-raises fk constraint violation error' do
    expect {
      tasks.try {
        tasks.create.call(user_id: 918_273_645)
      }
    }.to raise_error(ROM::SQL::ForeignKeyConstraintError, /user_id/)
  end

  it 're-raises database errors' do
    expect {
      Params.attribute :bogus_field
      users.try { users.create.call(name: 'some name', bogus_field: 23) }
    }.to raise_error(ROM::SQL::DatabaseError)
  end

  it 'supports [] syntax instead of call' do
    expect {
      Params.attribute :bogus_field
      users.try { users.create[name: 'some name', bogus_field: 23] }
    }.to raise_error(ROM::SQL::DatabaseError)
  end

  describe '#execute' do
    context 'with postgres adapter' do
      context 'with a single record' do
        it 'materializes the result' do
          result = container.command(:users).create.execute(name: 'Jane')
          expect(result).to eq([
            { id: 1, name: 'Jane' }
          ])
        end
      end

      context 'with multiple records' do
        it 'materializes the results' do
          result = container.command(:users).create.execute([
            { name: 'Jane' },
            { name: 'John' }
          ])
          expect(result).to eq([
            { id: 1, name: 'Jane' },
            { id: 2, name: 'John' }
          ])
        end
      end
    end

    context 'with other adapter', adapter: :sqlite do
      let(:uri) { SQLITE_DB_URI }

      context 'with a single record' do
        it 'materializes the result' do
          result = container.command(:users).create.execute(name: 'Jane')
          expect(result).to eq([
            { id: 1, name: 'Jane' }
          ])
        end
      end

      context 'with multiple records' do
        it 'materializes the results' do
          result = container.command(:users).create.execute([
            { name: 'Jane' },
            { name: 'John' }
          ])
          expect(result).to eq([
            { id: 1, name: 'Jane' },
            { id: 2, name: 'John' }
          ])
        end
      end
    end

    context 'with a composite pk', adapter: :mysql do
      before do
        conn.create_table?(:user_group) do
          primary_key [:user_id, :group_id]
          column :user_id, Integer, null: false
          column :group_id, Integer, null: false
        end

        configuration.relation(:user_group) do
          schema(infer: true)
        end

        configuration.commands(:user_group) do
          define(:create) { result :one }
        end
      end

      after do
        conn.drop_table(:user_group)
      end

      it 'materializes the result' do
        pending 'TODO: with a composite pk sequel returns 0 when inserting'

        command = container.commands[:user_group][:create]
        result = command.call(user_id: 1, group_id: 2)

        expect(result).to eql(user_id: 1, group_id: 2)
      end
    end
  end
end
