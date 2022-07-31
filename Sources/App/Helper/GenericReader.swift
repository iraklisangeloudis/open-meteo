import Foundation
import SwiftPFor2D

/**
 Generic domain that is required for the reader
 */
protocol GenericDomain {
    /// The grid definition. Could later be replaced with a more generic implementation
    var grid: RegularGrid { get }
    
    /// Time resoltuion of the deomain. 3600 for hourly, 10800 for 3-hourly
    var dtSeconds: Int { get }
    
    /// An instance to read elevation and sea mask information
    var elevationFile: OmFileReader { get }
    
    /// Where compressed time series files are stroed
    var omfileDirectory: String { get }
    
    /// The time length of each compressed time series file
    var omFileLength: Int { get }
}

/**
 Generic variable for the reader implementation
 */
protocol GenericVariable {
    /// The filename of the variable. Typically just `temperature_2m`
    var omFileName: String { get }
    
    /// The scalefactor to compress data
    var scalefactor: Float { get }
    
    /// Kind of interpolation for this variable. Used to interpolate from 1 to 3 hours
    var interpolation: InterpolationType { get }
}

/**
 Generic reader implementation that resolves a grid point and interpolates data
 */
struct GenericReader<Domain: GenericDomain, Variable: GenericVariable> {
    /// Regerence to the domain object
    let domain: Domain
    
    /// Grid index in data files
    let position: Int
    
    /// The desired time and resolution to read
    let time: TimerangeDt
    
    /// Elevation of the grid point
    let modelElevation: Float
    
    /// Latitude of the grid point
    let modelLat: Float
    
    /// Longitude of the grid point
    let modelLon: Float
    
    /// If set, use new data files
    let omFileSplitter: OmFileSplitter
    
    /// Return nil, if the coordinates are outside the domain grid
    public init?(domain: Domain, lat: Float, lon: Float, elevation: Float, mode: GridSelectionMode, time: TimerangeDt) throws {
        // check if coordinates are in domain, otherwise return nil
        guard let gridpoint = try domain.grid.findPoint(lat: lat, lon: lon, elevation: elevation, elevationFile: domain.elevationFile, mode: mode) else {
            return nil
        }
        self.domain = domain
        self.position = gridpoint.gridpoint
        self.time = time
        self.modelElevation = gridpoint.gridElevation
        
        omFileSplitter = OmFileSplitter(basePath: domain.omfileDirectory, nLocations: domain.grid.count, nTimePerFile: domain.omFileLength, yearlyArchivePath: nil)
        
        (modelLat, modelLon) = domain.grid.getCoordinates(gridpoint: gridpoint.gridpoint)
    }
    
    /// Prefetch data asynchronously. At the time `read` is called, it might already by in the kernel page cache.
    func prefetchData(variable: Variable) throws {
        try omFileSplitter.willNeed(variable: variable.omFileName, location: position, time: time)
    }
    
    /// Read data and interpolate if required
    func get(variable: Variable) throws -> [Float] {
        if time.dtSeconds == domain.dtSeconds {
            return try omFileSplitter.read(variable: variable.omFileName, location: position, time: time)
        }
        if time.dtSeconds > domain.dtSeconds {
            fatalError()
        }
        
        let interpolationType = variable.interpolation
        
        let timeLow = time.forInterpolationTo(modelDt: domain.dtSeconds).expandLeftRight(by: domain.dtSeconds*(interpolationType.padding-1))
        let dataLow = try omFileSplitter.read(variable: variable.omFileName, location: position, time: timeLow)
        
        var data = [Float]()
        data.reserveCapacity(time.count)
        switch interpolationType {
        case .linear:
            for t in time {
                let index = t.timeIntervalSince1970 / domain.dtSeconds - timeLow.range.lowerBound.timeIntervalSince1970 / domain.dtSeconds
                let fraction = Float(t.timeIntervalSince1970 % domain.dtSeconds) / Float(domain.dtSeconds)
                let A = dataLow[index]
                let B = index+1 >= dataLow.count ? A : dataLow[index+1]
                let h = A * (1-fraction) + B * fraction
                /// adjust it to scalefactor, otherwise interpolated values show more level of detail
                data.append(round(h * variable.scalefactor) / variable.scalefactor)
            }
        case .nearest:
            fatalError("Not implemented")
        case .solar_backwards_averaged:
            fatalError("Not implemented")
        case .hermite:
            for t in time {
                let index = t.timeIntervalSince1970 / domain.dtSeconds - timeLow.range.lowerBound.timeIntervalSince1970 / domain.dtSeconds
                let fraction = Float(t.timeIntervalSince1970 % domain.dtSeconds) / Float(domain.dtSeconds)
                
                let B = dataLow[index]
                let A = index-1 < 0 ? B : dataLow[index-1].isNaN ? B : dataLow[index-1]
                let C = index+1 >= dataLow.count ? B : dataLow[index+1].isNaN ? B : dataLow[index+1]
                let D = index+2 >= dataLow.count ? C : dataLow[index+2].isNaN ? B : dataLow[index+2]
                let a = -A/2.0 + (3.0*B)/2.0 - (3.0*C)/2.0 + D/2.0
                let b = A - (5.0*B)/2.0 + 2.0*C - D / 2.0
                let c = -A/2.0 + C/2.0
                let d = B
                let h = a*fraction*fraction*fraction + b*fraction*fraction + c*fraction + d
                /// adjust it to scalefactor, otherwise interpolated values show more level of detail
                data.append(round(h * variable.scalefactor) / variable.scalefactor)
            }
        case .hermite_backwards_averaged:
            fatalError("Not implemented")
        }
        return data
    }
}

extension TimerangeDt {
    func forInterpolationTo(modelDt: Int) -> TimerangeDt {
        let start = range.lowerBound.floor(toNearest: modelDt)
        let end = range.upperBound.ceil(toNearest: modelDt)
        return TimerangeDt(start: start, to: end, dtSeconds: modelDt)
    }
    func expandLeftRight(by: Int) -> TimerangeDt {
        return TimerangeDt(start: range.lowerBound.add(-1*by), to: range.upperBound.add(by), dtSeconds: dtSeconds)
    }
}
