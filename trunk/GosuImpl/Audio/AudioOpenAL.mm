#include <GosuImpl/MacUtility.hpp>
#include <GosuImpl/Audio/AudioFileMac.hpp>
#include <GosuImpl/Audio/ALChannelManagement.hpp>
#include <GosuImpl/Audio/OggFile.hpp>

#include <Gosu/Audio.hpp>
#include <Gosu/Math.hpp>
#include <Gosu/IO.hpp>
#include <Gosu/Utility.hpp>
#include <Gosu/Platform.hpp>

#include <boost/algorithm/string.hpp>
#include <boost/lexical_cast.hpp>
#include <boost/optional.hpp>

#include <cassert>
#include <cstdlib>
#include <algorithm>
#include <stdexcept>
#include <vector>

#include <OpenAL/al.h>
#include <OpenAL/alc.h>

#if __LP64__ || NS_BUILD_32_LIKE_64
typedef long NSInteger;
typedef unsigned long NSUInteger;
#else
typedef int NSInteger;
typedef unsigned int NSUInteger;
#endif

using namespace std;

namespace
{
    using namespace Gosu;
    
    /*GOSU_NORETURN void throwLastALError(const char* action)
    {
        string message = "OpenAL error " +
                         boost::lexical_cast<string>(alcGetError(alDevice));
        if (action)
            message += " while ", message += action;
        throw runtime_error(message);
    }

    inline void alCheck(const char* action = 0)
    {
        if (alcGetError(alDevice) != ALC_NO_ERROR)
            throwLastALError(action);
    }*/

    Song* curSong = 0;
}

Gosu::Audio::Audio()
{
    if (alChannelManagement)
        throw std::logic_error("Multiple Gosu::Audio instances not supported");
    alChannelManagement.reset(new ALChannelManagement);
}

Gosu::Audio::~Audio()
{
    alChannelManagement.reset();
}

void Gosu::Audio::update()
{
    if (Song::currentSong())
        Song::currentSong()->update();
}

Gosu::SampleInstance::SampleInstance(int handle, int extra)
: handle(handle), extra(extra)
{
}

bool Gosu::SampleInstance::playing() const
{
    NSUInteger source = alChannelManagement->sourceIfStillPlaying(handle, extra);
    if (source == ALChannelManagement::NO_SOURCE)
        return false;
    ALint state;
    alGetSourcei(source, AL_SOURCE_STATE, &state);
    return state == AL_PLAYING;
}

bool Gosu::SampleInstance::paused() const
{
    NSUInteger source = alChannelManagement->sourceIfStillPlaying(handle, extra);
    if (source == ALChannelManagement::NO_SOURCE)
        return false;
    ALint state;
    alGetSourcei(source, AL_SOURCE_STATE, &state);
    return state == AL_PAUSED;
}

void Gosu::SampleInstance::pause()
{
    NSUInteger source = alChannelManagement->sourceIfStillPlaying(handle, extra);
    if (source == ALChannelManagement::NO_SOURCE)
        return;
    alSourcePause(source);
}

void Gosu::SampleInstance::resume()
{
    NSUInteger source = alChannelManagement->sourceIfStillPlaying(handle, extra);
    if (source == ALChannelManagement::NO_SOURCE)
        return;
    ALint state;
    alGetSourcei(source, AL_SOURCE_STATE, &state);
    if (state == AL_PAUSED)
        alSourcePlay(source);
}

void Gosu::SampleInstance::stop()
{
    NSUInteger source = alChannelManagement->sourceIfStillPlaying(handle, extra);
    if (source == ALChannelManagement::NO_SOURCE)
        return;
    alSourceStop(source);
}

void Gosu::SampleInstance::changeVolume(double volume)
{
    NSUInteger source = alChannelManagement->sourceIfStillPlaying(handle, extra);
    if (source == ALChannelManagement::NO_SOURCE)
        return;
    alSourcef(source, AL_GAIN, volume);
}

void Gosu::SampleInstance::changePan(double pan)
{
    NSUInteger source = alChannelManagement->sourceIfStillPlaying(handle, extra);
    if (source == ALChannelManagement::NO_SOURCE)
        return;
    // TODO: This is not the old panning behavior!
    alSource3f(source, AL_POSITION, pan * 10, 0, 0);
}

void Gosu::SampleInstance::changeSpeed(double speed)
{
    NSUInteger source = alChannelManagement->sourceIfStillPlaying(handle, extra);
    if (source == ALChannelManagement::NO_SOURCE)
        return;
    alSourcef(source, AL_PITCH, speed);
}

struct Gosu::Sample::SampleData : boost::noncopyable
{
    NSUInteger buffer, source;

    SampleData(const AudioFile& audioFile)
    {
        alGenBuffers(1, &buffer);
        alBufferData(buffer,
                     audioFile.getFormatAndSampleRate().first,
                     &audioFile.getDecodedData().front(),
                     audioFile.getDecodedData().size(),
                     audioFile.getFormatAndSampleRate().second);
    }
    
    SampleData(OggFile& oggFile)
    {
        alGenBuffers(1, &buffer);
        alBufferData(buffer,
                     oggFile.format(),
                     &oggFile.decodedData().front(),
                     oggFile.decodedData().size(),
                     oggFile.sampleRate());
    }

    ~SampleData()
    {
        // It's hard to free things in the right order in Ruby/Gosu.
        // Make sure buffer isn't deleted after the context/device are shut down.
        
        if (!alChannelManagement)
            return;
            
        alDeleteBuffers(1, &buffer);
    }
};

Gosu::Sample::Sample(Audio& audio, const std::wstring& filename)
{
    bool isOgg;
    {
        char magicBytes[4];
        Gosu::File file(filename);
        file.read(0, 4, magicBytes);
        isOgg = magicBytes[0] == 'O' && magicBytes[1] == 'g' &&
                magicBytes[2] == 'g' && magicBytes[3] == 'S';
    }
    if (isOgg)
    {
        Gosu::Buffer buffer;
        Gosu::loadFile(buffer, filename);
        OggFile oggFile(buffer.frontReader());
        data.reset(new SampleData(oggFile));
    }
    else
    {
        AudioFile audioFile(filename);
        data.reset(new SampleData(audioFile));
    }
}

Gosu::Sample::Sample(Audio& audio, Reader reader)
{
    bool isOgg;
    {
        char magicBytes[4];
        Reader anotherReader = reader;
        anotherReader.read(magicBytes, 4);
        isOgg = magicBytes[0] == 'O' && magicBytes[1] == 'g' &&
                magicBytes[2] == 'g' && magicBytes[3] == 'S';
    }
    if (isOgg)
    {
        OggFile oggFile(reader);
        data.reset(new SampleData(oggFile));
    }
    else
    {
        AudioFile audioFile(reader.resource());
        data.reset(new SampleData(audioFile));
    }
}

Gosu::Sample::~Sample()
{
}

Gosu::SampleInstance Gosu::Sample::play(double volume, double speed,
    bool looping) const
{
    return playPan(0, volume, speed, looping);
}

Gosu::SampleInstance Gosu::Sample::playPan(double pan, double volume,
    double speed, bool looping) const
{
    std::pair<int, int> channelAndToken = alChannelManagement->reserveChannel();
    if (channelAndToken.first == ALChannelManagement::NO_FREE_CHANNEL)
        return Gosu::SampleInstance(channelAndToken.first, channelAndToken.second);
        
    NSUInteger source = alChannelManagement->sourceIfStillPlaying(channelAndToken.first,
                                                                  channelAndToken.second);
    assert(source != ALChannelManagement::NO_SOURCE);
    alSourcei(source, AL_BUFFER, data->buffer);
    // TODO: This is not the old panning behavior!
    alSource3f(source, AL_POSITION, pan * 10, 0, 0);
    alSourcef(source, AL_GAIN, volume);
    alSourcef(source, AL_PITCH, speed);
    alSourcei(source, AL_LOOPING, looping ? AL_TRUE : AL_FALSE);
    alSourcePlay(source);

    return Gosu::SampleInstance(channelAndToken.first, channelAndToken.second);
}

class Gosu::Song::BaseData : boost::noncopyable
{
    double volume_;

protected:
    BaseData() : volume_(1) {}
    virtual void applyVolume() = 0;

public:
    virtual ~BaseData() {}
    
    virtual void play(bool looping) = 0;
    virtual void pause() = 0;
    virtual bool paused() const = 0;
    virtual void stop() = 0;
    
    virtual void update() = 0;
    
    double volume() const
    {
        return volume_;
    }
    
    void changeVolume(double volume)
    {
        volume_ = clamp(volume, 0.0, 1.0);
        applyVolume();
    }
};

class Gosu::Song::StreamData : public BaseData
{
    OggFile oggFile;
    NSUInteger buffers[2];
    boost::optional<std::pair<int, int> > channel;
    
    void applyVolume()
    {
        int source = lookupSource();
        if (source != ALChannelManagement::NO_SOURCE)
            alSourcef(source, AL_GAIN, volume());
    }
    
    int lookupSource() const
    {
        if (!channel)
            return ALChannelManagement::NO_SOURCE;
        return alChannelManagement->sourceIfStillPlaying(channel->first, channel->second);
    }
    
    bool streamTo(NSUInteger source, NSUInteger buffer)
    {
        #ifdef GOSU_IS_IPHONE
        static const unsigned BUFFER_SIZE = 4096 * 4;
        #else
        static const unsigned BUFFER_SIZE = 4096 * 8;
        #endif
        char audioData[BUFFER_SIZE];
        std::size_t readBytes = oggFile.readData(audioData, BUFFER_SIZE);
        if (readBytes > 0)
            alBufferData(buffer, oggFile.format(), audioData, readBytes, oggFile.sampleRate());
        return readBytes > 0;
    }
    
public:
    StreamData(Reader reader)
    : oggFile(reader)
    {
        alGenBuffers(2, buffers);
    }
    
    ~StreamData()
    {
        stop();
        alDeleteBuffers(2, buffers);
    }
    
    void play(bool looping)
    {
        stop();
        oggFile.rewind();
        
        channel = alChannelManagement->reserveChannel();
        int source = lookupSource();
        if (source != ALChannelManagement::NO_SOURCE)
        {
            streamTo(source, buffers[0]);
            streamTo(source, buffers[1]);

            alSource3f(source, AL_POSITION, 0, 0, 0);
            alSourcef(source, AL_GAIN, volume());
            alSourcef(source, AL_PITCH, 1);
            alSourcei(source, AL_LOOPING, AL_FALSE); // need to implement this manually...

            alSourceQueueBuffers(source, 2, buffers);
            alSourcePlay(source);
        }
    }

    void stop()
    {
        int source = lookupSource();
        if (source != ALChannelManagement::NO_SOURCE)
        {
            alSourceStop(source);
            int queued;
            alGetSourcei(source, AL_BUFFERS_QUEUED, &queued);
            NSUInteger buffer;
            while (queued--)
                alSourceUnqueueBuffers(source, 1, &buffer);
            
            int processed;
            alGetSourcei(source, AL_BUFFERS_PROCESSED, &processed);
            while (processed--)
                alSourceUnqueueBuffers(source, 1, &buffer);
        }
        channel.reset();
    }
    
    void pause()
    {
        int source = lookupSource();
        if (source != ALChannelManagement::NO_SOURCE)
            alSourcePause(source);
    }
    
    bool paused() const
    {
        int source = lookupSource();
        if (source == ALChannelManagement::NO_SOURCE)
            return false;
        ALint state;
        alGetSourcei(source, AL_SOURCE_STATE, &state);
        return state == AL_PAUSED;
    }
    
    void update()
    {
        int source = lookupSource();
        if (source == ALChannelManagement::NO_SOURCE)
        {
            stop();
            return;
        }
        
        int processed;
        bool active = true;
        
        alGetSourcei(source, AL_BUFFERS_PROCESSED, &processed);
        
        for (int i = 0; i < processed && active; ++i)
        {
            NSUInteger buffer;
            alSourceUnqueueBuffers(source, 1, &buffer);
            active = streamTo(source, buffer);
            alSourceQueueBuffers(source, 1, &buffer);
        }

        // We got starved, need to call play again
        if (processed == 2 && active)
            alSourcePlay(source);
        
        if (!active)
        {
            channel.reset();
            curSong = 0;
        }
    }
};

void Gosu::Song::update()
{
    data->update();
}

Gosu::Song::Song(Audio& audio, const std::wstring& filename)
{
    Buffer buf;
	loadFile(buf, filename);
	
    // Forward.
	Song(audio, stStream, buf.frontReader()).data.swap(data);
}

Gosu::Song::Song(Audio& audio, Type type, Reader reader)
: data(new StreamData(reader))
{
}

Gosu::Song::~Song()
{
    if (alChannelManagement)
        stop();
}

Gosu::Song* Gosu::Song::currentSong()
{
    return curSong;
}

void Gosu::Song::play(bool looping)
{
    if (curSong && curSong != this)
    {
        curSong->stop();
        assert(curSong == 0);
    }

    data->play(looping);
    curSong = this; // may be redundant
}

void Gosu::Song::pause()
{
    if (curSong == this)
        data->pause(); // may be redundant
}

bool Gosu::Song::paused() const
{
    return curSong == this && data->paused();
}

void Gosu::Song::stop()
{
    if (curSong == this)
    {
        data->stop();
        curSong = 0;
    }
}

bool Gosu::Song::playing() const
{
    return curSong == this && !data->paused();
}

double Gosu::Song::volume() const
{
    return data->volume();
}

void Gosu::Song::changeVolume(double volume)
{
    data->changeVolume(volume);
}