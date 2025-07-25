import std.stdio, std.string, std.file;
import std.path, std.range, std.algorithm;
import std.conv, std.format, std.array;
import std.typecons, std.conv, std.format;
static import std.parallelism;

import progress, colored;

import dapplicationbase, dtermutils, luaaddon.tocparser;
import dfileutils.extractor;

import constants, api.path, todofilereader;
import generator, extractor;

@GetOptPassThru
struct CommandLineOptions
{
	@GetOptOptions("Sets the directory that should be scanned. [Default: .].")
	string dir;
	@GetOptOptions("The pattern to use. [Default: *.*]")
	string pattern;
	@GetOptOptions("Will only search the passed file name.")
	string file;
	@GetOptOptions("The output format the results should be in. [Default: stdout].")
	string format;
	@GetOptOptions("A list of file extensions to ignore separated by comma. [d,cpp,rust]")
	string ignore;
	@GetOptOptions("Used to display only the tag passed separated by commas. [INFO, FIXME, TODO]")
	string tags;
	@GetOptOptions("Starts an interactive session used to create a new generator.", "", "create-generator")
	bool createGenerator;
	@GetOptOptions("Removes an installed generator.", "", "remove-generator")
	string removeGenerator;
	@GetOptOptions("Generates a list of installed generators.")
	bool list;
}

class TodoListGenApp : Application!CommandLineOptions
{
public:
	override void onCreate()
	{
		setupEnvironment();
		handleArguments();
	}

	void handleArguments()
	{
		if(!isHelpCommand())
		{
			if(Options.hasFile()) // --file argument was passed
			{
				immutable string fileName = Options.getFile();
				processFile(fileName);
			}
			else if(Options.hasList())
			{
				createListOfGenerators();
			}
			else if(Options.hasCreateGenerator())
			{
				createGenerator();
			}
			else if(Options.hasRemoveGenerator())
			{
				removeGenerator();
			}
			else
			{
				processDir();
			}
		}
	}

private:
	void setupEnvironment()
	{
		paths_ = ApplicationPaths.getInstance();
		// FIXME: Calling create works and uses user's .config dir. Call to setAddonName doesn't?
		paths_.create(Options.getFormat("stdout"));
		paths_.setAddonName(Options.getFormat("stdout"));
		ensureConfigDirExists();
		extractGenerators();
	}

	auto getDirList(const string name, SpanMode mode)
	{
		auto dirs = dirEntries(name, mode)
			.filter!(a => a.isDir && !a.name.startsWith("."))
			.array;

		return sort(dirs);
	}

	void createListOfGenerators()
	{
		writeln("The following generators are available:");
		writeln;

		foreach(dirName; getDirList(paths_.getBaseAddonDir(), SpanMode.shallow))
		{
			TocParser!() parser;
			immutable string baseName = dirName.baseName;
			immutable string tocFileName = buildNormalizedPath(dirName, baseName ~ ".toc");

			if(tocFileName.exists && baseName != "creator")
			{
				parser.loadFile(tocFileName);

				immutable string description = parser.getDescription();
				immutable string name = parser.getName();

				writeln(name.blue.bold,  " - ", description);
			}

		}
	}

	void ensureConfigDirExists() @trusted
	{
		immutable string configPath = paths_.getConfigFilesDir();

		debug
		{
			immutable string configFile = buildNormalizedPath(configPath, "config.lua");

			if(configFile.exists)
			{
				//INFO: We remove the config file here so any changes to default.config.lua will be in sync with config.lua in debug mode.
				configFile.remove;
			}
		}

		if(!configPath.exists)
		{
			configPath.mkdirRecurse;
		}
	}

	void processFile(const string fileName) @trusted
	{
		if(fileName.exists)
		{
			auto addon = new Generator;
			immutable bool created = addon.create(Options.getFormat("stdout"));

			if(created)
			{
				auto reader = new TodoFileReader;
				auto tasks = reader.readFile(fileName);

				writeln("Processing ", fileName);

				if(tasks.length > 0)
				{
					addon.callFunction("OnCreate");
					addon.processTasks(fileName, tasks, Yes.isLastFile);
					addon.callFunction("OnDestroy");
				}
				else
				{
					writeln("NO TASKS FOUND!");
				}
			}
			else
			{
				writeln(Options.getFormat("stdout"), " output format not found!");
			}
		}
		else
		{
			writeln("Failed to open ", fileName, ". File not found!");
		}
	}

	void processDir() @trusted
	{
		auto addon = new Generator;
		immutable bool created = addon.create(Options.getFormat("stdout"));

		if(created)
		{
			immutable string dir = Options.getDir(".");
			immutable string pattern = Options.getPattern("*.*");
			immutable auto filesLength = walkLength(dirEntries(dir, pattern, SpanMode.breadth));

			TaskValues[][string] files;
			auto reader = new TodoFileReader;
			ChargingBar progress = new ChargingBar();
			size_t counter;

			progress.message = { return "Searching"; };
			progress.suffix = { return format("%0.0f", progress.percent).to!string ~ "% "; };
			progress.width = 64;
			progress.max = filesLength;

			writeln(filesLength, " files to process.");
			addon.callFunction("OnCreate");

			foreach(DirEntry e; std.parallelism.parallel(dirEntries(dir, pattern, SpanMode.breadth)))
			{
				++counter;
				immutable string name = buildNormalizedPath(e.name);

				if(e.isFile)
				{
					 // TODO: Find a better way to represent hidden files
					if(!name.startsWith(".") && !isIgnoredFileType(name))
					{
						TaskValues[] tasks = reader.readFile(name, Options.getTags());

						if(tasks.length > 0)
						{
							files[name] ~= tasks;
						}
					}
				}

				progress.next();
			}

			progress.finish();

			if(files.length > 0)
			{
				counter = 0;

				foreach(fileName; sort(files.keys))
				{
					counter++;

					if(counter == files.length)
					{
						addon.processTasks(fileName, files[fileName], Yes.isLastFile);
					}
					else
					{
						addon.processTasks(fileName, files[fileName], No.isLastFile);
					}
				}

				addon.callFunction("OnDestroy");
			}
			else
			{
				writeln("NO TASKS FOUND!");
			}
		}
		else
		{
			writeln(Options.getFormat("stdout"), " output format not found!");
		}
	}

	bool isIgnoredFileType(const string fileName)
	{
		immutable auto fileExtensions = Options.getIgnore("").split(",");

		foreach(extension; fileExtensions)
		{
			if(fileName.endsWith(extension))
			{
				return true;
			}
		}

		return false;
	}

	bool hasGenerator(const string name)
	{
		foreach(dirName; getDirList(paths_.getBaseAddonDir(), SpanMode.shallow))
		{
			if(dirName.baseName == name)
			{
				return true;
			}
		}

		return false;
	}

	void createGenerator()
	{
		//INFO: We have to set the format here since its not passed when using --create-generator
		paths_.setAddonName(Options.getFormat("creator"));
		ensureConfigDirExists();

		auto addon = new Generator;
		immutable bool created = addon.create(Options.getFormat("creator"));

		if(created)
		{
			addon.callFunction("OnCreate");
			addon.callFunction("OnDestroy");
		}
		else
		{
			writeln("Failed to start Creator interactive session.");
		}
	}

	void removeGenerator()
	{
		immutable string generatorName = Options.getRemoveGenerator();
		immutable string generatorToRemove = buildNormalizedPath(paths_.getBaseAddonDir(), generatorName);

		if(generatorToRemove.exists)
		{
			immutable bool shouldRemove = confirmationPrompt("Are you sure you want to remove " ~ generatorName ~ " (y/n): ");

			if(shouldRemove)
			{
				writeln("Removing ", generatorToRemove);
				rmdirRecurse(generatorToRemove);

				if(generatorToRemove.exists)
				{
					writeln("Failed to remove ", generatorName);
				}
			}
		}
		else
		{
			writeln(generatorName, " does not exist!");
		}
	}

	void extractGenerators()
	{
		debug
		{}
		else
		{
			extractImportFiles!generatorFilesList(paths_.getBaseAddonDir(), Yes.overwrite);
			extractImportFiles!moduleFilesList(paths_.getModuleDir(), Yes.overwrite);
		}
	}

private:
	ApplicationPaths paths_;
}

void main(string[] arguments)
{
	auto app = new TodoListGenApp;
	app.create(ORGANIZATION_NAME, APPLICATION_NAME, arguments);
}
